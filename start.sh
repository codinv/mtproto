#!/bin/bash
set -e

# Enable debug output if DEBUG=1
[ "$DEBUG" = "1" ] && set -x

# Defaults
: "${WORKERS:=1}"
INTERNAL_PORT=8443
DISPLAY_PORT="${EXTERNAL_PORT:-$INTERNAL_PORT}"

# External IP
EXTERNAL_IP=$(curl -s --max-time 5 -4 https://api.ipify.org || \
              curl -s --max-time 5 -4 https://ifconfig.me)

# Internal IP
INTERNAL_IP=$(ip -4 route get 8.8.8.8 | awk '/src/ {print $7; exit}')

if [ -z "$EXTERNAL_IP" ]; then
  echo "[F] Cannot determine external IP address."
  exit 3
fi

if [ -z "$INTERNAL_IP" ]; then
  echo "[F] Cannot determine internal IP address."
  exit 4
fi

# Secret
if [ "$SECRET" = "auto" ] || [ -z "$SECRET" ]; then
  SECRET=$(head -c 16 /dev/urandom | xxd -ps)
  echo "[+] Generated secret: $SECRET"
fi

# Validate secret
if ! echo "$SECRET" | grep -qE '^[0-9a-fA-F]{32}$'; then
  echo "[F] SECRET must be exactly 32 hex characters"
  exit 1
fi

# Workers
if [ "$WORKERS" -gt 1 ]; then
  WORKER_ARGS="-M $WORKERS"
else
  WORKER_ARGS=""
fi

echo "======================================"
echo "MTProto proxy starting"
echo "[*] External IP: $EXTERNAL_IP"
echo "[*] Internal IP: $INTERNAL_IP"
echo "[*] Internal Port: $INTERNAL_PORT"
echo "[*] Public Port (for link): $DISPLAY_PORT"
echo "[*] Workers: $WORKERS"
echo
echo "Use this secret to connect to your proxy:"
echo "tg://proxy?server=${EXTERNAL_IP}&port=${DISPLAY_PORT}&secret=${SECRET}"
echo "https://t.me/proxy?server=${EXTERNAL_IP}&port=${DISPLAY_PORT}&secret=${SECRET}"
echo "======================================"

# Start proxy
# Внутри контейнера всегда слушаем INTERNAL_PORT (8443)
exec /usr/local/bin/mtproto-proxy \
    -p 8888 \
    -H "$INTERNAL_PORT" \
    -S "$SECRET" \
    --aes-pwd /etc/mtproto-proxy/proxy-secret \
    /etc/mtproto-proxy/proxy-multi.conf \
    $WORKER_ARGS \
    --allow-skip-dh \
    --nat-info "$INTERNAL_IP:$EXTERNAL_IP"
