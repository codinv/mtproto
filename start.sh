#!/bin/bash
# MTProto proxy entrypoint.
#
# Environment:
#   SECRET            "auto" (default) or up to 16 comma-separated 32-hex secrets
#   SECRET_COUNT      how many secrets to generate when SECRET=auto (default 1)
#   TLS_DOMAIN        enable Fake-TLS ("ee" secrets) and masquerade as this domain
#   TAG / PROXY_TAG   32-hex proxy tag from @MTProxybot (optional)
#   WORKERS           worker processes (default 1; keep 1 with Fake-TLS)
#   EXTERNAL_PORT     public port used in the generated links (default 8443)
#   EXTERNAL_IP       public IPv4; auto-detected when empty
#   INTERNAL_IP       container IPv4; auto-detected when empty
#   CONFIG_REFRESH_INTERVAL  seconds between Telegram config checks (default 86400, 0 = off)
#   RUN_UID / RUN_GID  user the proxy runs as (default 10001:10001)
#   DEBUG=1           shell trace
# Any extra arguments are passed to mtproto-proxy as-is.

set -Eeuo pipefail

if [ "${DEBUG:-0}" = "1" ]; then
  set -x
fi

log()  { echo "[*] $*"; }
warn() { echo "[!] $*" >&2; }
die()  { echo "[F] $1" >&2; exit "${2:-1}"; }

# ---------- constants (overridable for tests) ----------
PROXY_BIN="${PROXY_BIN:-/usr/local/bin/mtproto-proxy}"
BAKED_DIR="${BAKED_DIR:-/etc/mtproto-proxy}"   # config baked into the image (fallback)
RUN_DIR="${RUN_DIR:-/tmp/mtproto}"             # working copy, refreshed at runtime
DATA_DIR="${DATA_DIR:-/data}"                  # persistent volume (generated secrets)
INTERNAL_PORT=8443
STATS_PORT=8888

SECRET_URL="https://core.telegram.org/getProxySecret"
CONFIG_URL="https://core.telegram.org/getProxyConfig"

# ---------- permissions ----------
# The container starts as root only to fix the owner of the data folder (a host
# folder mounted at /data is usually owned by root or by the host user), then
# the script re-runs itself as the unprivileged proxy user. Needs the
# CHOWN, SETUID and SETGID capabilities. If the container is started with an
# explicit non-root user (docker run --user ...), this block is skipped.
RUN_UID="${RUN_UID:-10001}"
RUN_GID="${RUN_GID:-10001}"
if [ "$(id -u)" = "0" ]; then
  mkdir -p "$DATA_DIR" 2>/dev/null || warn "cannot create $DATA_DIR"
  # folder first, then the secret inside it (the folder may be closed to others)
  for path in "$DATA_DIR" "$DATA_DIR/secret"; do
    if [ -e "$path" ] && [ "$(stat -c '%u:%g' "$path")" != "$RUN_UID:$RUN_GID" ]; then
      chown "$RUN_UID:$RUN_GID" "$path" 2>/dev/null \
        || warn "cannot change the owner of $path (the CHOWN capability or a root-squashed share?); secrets may not be saved"
    fi
  done
  # After the uid change the process keeps no capabilities (checked in tests), so
  # there is no need to also shrink the bounding set: that would require SETPCAP.
  setpriv --reuid="$RUN_UID" --regid="$RUN_GID" --clear-groups true 2>/dev/null \
    || die "cannot drop root privileges: with cap_drop: [ALL] also add cap_add: [CHOWN, SETUID, SETGID]" 5
  exec setpriv --reuid="$RUN_UID" --regid="$RUN_GID" --clear-groups bash "$0" "$@"
fi

# ---------- input validation ----------
WORKERS="${WORKERS:-1}"
[[ "$WORKERS" =~ ^[0-9]+$ ]] && [ "$WORKERS" -ge 1 ] || die "WORKERS must be a positive integer"

EXTERNAL_PORT="${EXTERNAL_PORT:-$INTERNAL_PORT}"
[[ "$EXTERNAL_PORT" =~ ^[0-9]+$ ]] && [ "$EXTERNAL_PORT" -ge 1 ] && [ "$EXTERNAL_PORT" -le 65535 ] \
  || die "EXTERNAL_PORT must be a number between 1 and 65535"

SECRET_COUNT="${SECRET_COUNT:-1}"
[[ "$SECRET_COUNT" =~ ^[0-9]+$ ]] && [ "$SECRET_COUNT" -ge 1 ] && [ "$SECRET_COUNT" -le 16 ] \
  || die "SECRET_COUNT must be a number between 1 and 16"

CONFIG_REFRESH_INTERVAL="${CONFIG_REFRESH_INTERVAL:-86400}"
[[ "$CONFIG_REFRESH_INTERVAL" =~ ^[0-9]+$ ]] || die "CONFIG_REFRESH_INTERVAL must be a number of seconds (0 = off)"

TAG="${TAG:-${PROXY_TAG:-}}"
if [ -n "$TAG" ] && ! [[ "$TAG" =~ ^[0-9a-fA-F]{32}$ ]]; then
  die "TAG must be exactly 32 hex characters (get it from @MTProxybot)"
fi

TLS_DOMAIN="${TLS_DOMAIN:-}"
TLS_DOMAIN="${TLS_DOMAIN,,}"
if [ -n "$TLS_DOMAIN" ]; then
  # plain host name only: no scheme, port or path
  [[ "$TLS_DOMAIN" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]] \
    || die "TLS_DOMAIN must be a bare host name like www.example.com (no https://, port or path)"
fi

# ---------- helpers ----------
is_hex32() { [[ "$1" =~ ^[0-9a-fA-F]{32}$ ]]; }
hex_encode() { printf '%s' "$1" | od -An -tx1 | tr -d ' \n'; }
gen_secret() { head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n'; }

detect_external_ip() {
  local url ip
  for url in https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com; do
    ip=$(curl -4 -fsS --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]') || true
    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      echo "$ip"
      return 0
    fi
  done
  return 1
}

detect_internal_ip() {
  ip -4 route get 8.8.8.8 2>/dev/null \
    | awk '{ for (i = 1; i < NF; i++) if ($i == "src") { print $(i + 1); exit } }' || true
}

# Download $1 to $2 only if the result looks sane ($3 = secret|config).
# Returns 0 and leaves $2 untouched when nothing could be fetched.
fetch_to() {
  local url="$1" dest="$2" kind="$3" tmp size
  tmp=$(mktemp "${dest}.XXXXXX") || return 1
  if ! curl -fsS --retry 2 --connect-timeout 5 --max-time 20 -o "$tmp" "$url" 2>/dev/null; then
    rm -f "$tmp"; return 1
  fi
  size=$(wc -c < "$tmp")
  case "$kind" in
    secret) [ "$size" -ge 32 ] && [ "$size" -le 512 ] || { rm -f "$tmp"; return 1; } ;;
    config) grep -Eq '^proxy_for[[:space:]]' "$tmp" && grep -Eq '^default[[:space:]]' "$tmp" \
              || { rm -f "$tmp"; return 1; } ;;
  esac
  chmod 644 "$tmp"
  mv -f "$tmp" "$dest"
}

# ---------- Telegram config (secret + DC list) ----------
mkdir -p "$RUN_DIR"
for f in proxy-secret proxy-multi.conf; do
  [ -s "$RUN_DIR/$f" ] || cp "$BAKED_DIR/$f" "$RUN_DIR/$f"
done
if fetch_to "$SECRET_URL" "$RUN_DIR/proxy-secret" secret; then
  log "proxy-secret refreshed from core.telegram.org"
else
  warn "could not refresh proxy-secret, using the cached copy"
fi
if fetch_to "$CONFIG_URL" "$RUN_DIR/proxy-multi.conf" config; then
  log "proxy-multi.conf refreshed from core.telegram.org"
else
  warn "could not refresh proxy-multi.conf, using the cached copy"
fi

# ---------- addresses ----------
EXTERNAL_IP="${EXTERNAL_IP:-}"
if [ -z "$EXTERNAL_IP" ]; then
  EXTERNAL_IP=$(detect_external_ip) || die "Cannot determine external IP address (set EXTERNAL_IP)" 3
fi
INTERNAL_IP="${INTERNAL_IP:-}"
if [ -z "$INTERNAL_IP" ]; then
  INTERNAL_IP=$(detect_internal_ip)
fi
[ -n "$INTERNAL_IP" ] || die "Cannot determine internal IP address (set INTERNAL_IP)" 4

# ---------- secrets ----------
SECRETS=()
if [ "${SECRET:-auto}" = "auto" ] || [ -z "${SECRET:-}" ]; then
  # generated once and kept in the volume, so links survive restarts and upgrades
  if [ -r "$DATA_DIR/secret" ]; then
    while IFS= read -r line; do
      line="${line//[[:space:]]/}"
      if [ -n "$line" ]; then
        is_hex32 "$line" || die "$DATA_DIR/secret contains an invalid secret; delete the file to regenerate"
        SECRETS+=("${line,,}")
      fi
    done < "$DATA_DIR/secret"
  fi
  generated=0
  while [ "${#SECRETS[@]}" -lt "$SECRET_COUNT" ]; do
    SECRETS+=("$(gen_secret)")
    generated=1
  done
  if [ "$generated" = 1 ]; then
    if mkdir -p "$DATA_DIR" 2>/dev/null && printf '%s\n' "${SECRETS[@]}" > "$DATA_DIR/secret" 2>/dev/null; then
      log "Generated secret(s) saved to $DATA_DIR/secret"
    else
      warn "Generated secret(s) but $DATA_DIR is not writable, so they will change on the next start. Mount a folder or volume at $DATA_DIR."
    fi
  fi
else
  IFS=',' read -r -a raw_secrets <<< "$SECRET"
  for s in "${raw_secrets[@]}"; do
    s="${s//[[:space:]]/}"
    [ -n "$s" ] || continue
    is_hex32 "$s" || die "Each SECRET must be exactly 32 hex characters (no dd/ee prefix, no domain). Got: '$s'"
    SECRETS+=("${s,,}")
  done
fi
[ "${#SECRETS[@]}" -ge 1 ] || die "No secrets configured"
[ "${#SECRETS[@]}" -le 16 ] || die "At most 16 secrets are supported"

# ---------- proxy arguments ----------
ARGS=(
  -p "$STATS_PORT"
  -H "$INTERNAL_PORT"
  --http-stats                  # required for the local /stats endpoint (used by HEALTHCHECK)
  --aes-pwd "$RUN_DIR/proxy-secret"
  --allow-skip-dh
  --nat-info "$INTERNAL_IP:$EXTERNAL_IP"
)
for s in "${SECRETS[@]}"; do ARGS+=(-S "$s"); done
[ -z "$TAG" ] || ARGS+=(-P "$TAG")
if [ -n "$TLS_DOMAIN" ]; then
  ARGS+=(-D "$TLS_DOMAIN")
  if [ "$WORKERS" -gt 1 ]; then
    warn "WORKERS>1 is not recommended with Fake-TLS (weaker replay protection)"
  fi
fi
if [ "$WORKERS" -gt 1 ]; then ARGS+=(-M "$WORKERS"); fi
ARGS+=("$@")
ARGS+=("$RUN_DIR/proxy-multi.conf")

# ---------- banner ----------
echo "======================================"
echo "MTProto proxy starting"
echo "[*] External IP: $EXTERNAL_IP"
echo "[*] Internal IP: $INTERNAL_IP"
echo "[*] Internal Port: $INTERNAL_PORT"
echo "[*] Public Port (for link): $EXTERNAL_PORT"
echo "[*] Workers: $WORKERS"
if [ -n "$TLS_DOMAIN" ]; then
  echo "[*] Mode: Fake-TLS (domain: $TLS_DOMAIN)"
  DOMAIN_HEX=$(hex_encode "$TLS_DOMAIN")
else
  echo "[*] Mode: classic with random padding (set TLS_DOMAIN to enable Fake-TLS)"
fi
[ -z "$TAG" ] || echo "[*] Proxy tag: set"
echo
echo "Use these links to connect to your proxy:"
for s in "${SECRETS[@]}"; do
  if [ -n "$TLS_DOMAIN" ]; then
    client_secret="ee${s}${DOMAIN_HEX}"
  else
    client_secret="dd${s}"
  fi
  echo "tg://proxy?server=${EXTERNAL_IP}&port=${EXTERNAL_PORT}&secret=${client_secret}"
  echo "https://t.me/proxy?server=${EXTERNAL_IP}&port=${EXTERNAL_PORT}&secret=${client_secret}"
  echo
done
echo "======================================"

# ---------- run ----------
# The proxy reads proxy-multi.conf only at start-up (SIGHUP is a no-op), so a
# background watcher checks for a changed Telegram config and restarts the
# proxy by stopping it; the container's restart policy brings it back up.
REFRESH_FLAG="$RUN_DIR/.restart-for-new-config"
rm -f "$REFRESH_FLAG"

"$PROXY_BIN" "${ARGS[@]}" &
PROXY_PID=$!

stop_proxy() { kill -TERM "$PROXY_PID" 2>/dev/null || true; }
trap stop_proxy TERM INT

WATCHER_PID=""
if [ "$CONFIG_REFRESH_INTERVAL" -gt 0 ]; then
  (
    trap - TERM INT
    while sleep "$CONFIG_REFRESH_INTERVAL"; do
      tmp_conf=$(mktemp "$RUN_DIR/check.XXXXXX") || continue
      if fetch_to "$CONFIG_URL" "$tmp_conf" config && ! cmp -s "$tmp_conf" "$RUN_DIR/proxy-multi.conf"; then
        mv -f "$tmp_conf" "$RUN_DIR/proxy-multi.conf"
        fetch_to "$SECRET_URL" "$RUN_DIR/proxy-secret" secret || true
        echo "[*] Telegram proxy config changed, restarting to apply it"
        : > "$REFRESH_FLAG"
        kill -TERM "$PROXY_PID" 2>/dev/null || true
        break
      fi
      rm -f "$tmp_conf"
    done
  ) &
  WATCHER_PID=$!
fi

rc=0
while kill -0 "$PROXY_PID" 2>/dev/null; do
  wait "$PROXY_PID" && rc=0 || rc=$?
done

if [ -n "$WATCHER_PID" ]; then
  kill "$WATCHER_PID" 2>/dev/null || true
fi

if [ -e "$REFRESH_FLAG" ]; then
  exit 75
fi
exit "$rc"
