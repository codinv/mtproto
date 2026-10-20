# 🛰️ MTProto Proxy (Docker, ubuntu:24.04)

A lightweight **Telegram MTProto Proxy** built on **ubuntu:24.04**.
Fully containerized, minimal, and production-ready.

---

## 🚀 Description

This Docker image provides a simple and secure way to run a Telegram MTProto proxy server.
Based on the official [TelegramMessenger/MTProxy](https://github.com/TelegramMessenger/MTProxy) source,
built from the latest upstream `master`. The exact commit is stored in the image label `io.github.telegrammessenger.mtproxy.ref` (`docker inspect <image>`) and printed by the proxy at start-up.

What it does for you:

- **Fake-TLS** (`ee` secrets): set `TLS_DOMAIN` and the proxy looks like a normal HTTPS site to DPI.
- **Always fresh Telegram config**: `proxy-secret` and `proxy-multi.conf` are downloaded on every start and re-checked once a day. If the config changed, the proxy stops and the container's restart policy (`restart: unless-stopped` in the example) brings it back with the new config.
- **Persistent secret**: with `SECRET=auto` the secret is generated once and kept in the `./data` folder next to your compose file.
- **Multiple secrets** and an optional **proxy tag** (sponsored channel from [@MTProxybot](https://t.me/MTProxybot)).
- **Healthcheck** based on the proxy's local stats endpoint.

> ⚠️ The image is **linux/amd64 only**: upstream MTProxy uses x86 AES-NI/PCLMUL instructions.

---

## 🐳 Docker Compose Example

```yaml
# docker-compose.yml
services:
  mtproto:
    image: ghcr.io/codinv/mtproto
    container_name: mtproto-proxy
    restart: unless-stopped
    # Using bridge mode is standard for standalone proxy containers
    network_mode: bridge
    ports:
      # Map host port to container port 8443.
      # Common choices for host port are 443, 2053, or 8443.
      - "443:8443"
    volumes:
      - ./data:/data
    environment:
      - SECRET=auto
      - TLS_DOMAIN=www.google.com
      - WORKERS=1
      - EXTERNAL_PORT=443
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    cap_add:
      - CHOWN
      - SETUID
      - SETGID
    ulimits:
      nofile:
        soft: 131072
        hard: 131072
```

The full example is in [`docker-compose.yaml`](docker-compose.yaml).

---

## 🔑 Secrets

With `SECRET=auto` (the default) the container generates a secret on the first start and stores it in `/data/secret`.
Mount a host folder at `/data` (`./data:/data` in the example) to keep it across restarts and upgrades. You don't need to create the folder or set permissions: on start the container creates it if needed, fixes its owner and then runs the proxy as an unprivileged user (uid/gid `10001`). For this the container needs the `CHOWN`, `SETUID` and `SETGID` capabilities, which is why the example has `cap_drop: [ALL]` followed by `cap_add`.

The secret lives in plain sight in `./data/secret`. Back it up, or delete it to get a new one. The folder and the file belong to uid `10001` on the host, so use `sudo` to edit or delete them. A Docker named volume (`mtproto-data:/data`) works the same way.

If you start the container with an explicit non-root user (`user:` in compose), the ownership step is skipped and the folder must already be writable by that user.

To use your own secret, create 32 hex characters:

```bash
head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n'
```

Give it **without** any `dd`/`ee` prefix and without a domain: the container adds them to the links it prints.
You can pass up to 16 secrets separated by commas, or ask for several generated ones with `SECRET_COUNT`.

---

## 🥷 Fake-TLS and classic mode

| Mode | How to enable | Secret in the client link |
| :--- | :--- | :--- |
| **Fake-TLS** (recommended) | set `TLS_DOMAIN=<site>` | `ee` + secret + hex of the domain |
| Classic with random padding | leave `TLS_DOMAIN` empty | `dd` + secret |

Notes:

- With `TLS_DOMAIN` set, the proxy accepts **only** Fake-TLS connections. Old links with a plain or `dd` secret stop working, so share the new links from the container logs.
- Choose a popular site that supports TLS 1.3 and is reachable from your server. The proxy checks the domain at start-up and logs the result; if the check fails it keeps running with default settings.
- Keep `WORKERS=1` with Fake-TLS (upstream recommends it for replay protection).
- Fake-TLS makes the proxy look like HTTPS, but it is not a guarantee against blocking: keep the link private.

---

## 🌐 Connect via Telegram

Start the container and read the links from the logs:

```bash
docker compose up -d
docker logs mtproto-proxy
```

Links look like this (server IP `1.2.3.4`, port `443`):

```
tg://proxy?server=1.2.3.4&port=443&secret=ee<secret><domain-in-hex>
https://t.me/proxy?server=1.2.3.4&port=443&secret=ee<secret><domain-in-hex>
```

> ⚠️ **Note:** The proxy container always listens on port **8443** internally. Use `EXTERNAL_PORT` to ensure the generated links in logs show your public-facing port correctly.

---

## ⚙️ Environment Variables

| Variable | Description | Default |
| :--- | :--- | :--- |
| `SECRET` | `auto` to generate (and persist in `/data`), or 32-char hex secret(s), comma-separated, up to 16 | `auto` |
| `SECRET_COUNT` | How many secrets to generate when `SECRET=auto` (1–16) | `1` |
| `TLS_DOMAIN` | Enables Fake-TLS and masquerades as this site, e.g. `www.google.com` | empty (classic mode) |
| `TAG` (or `PROXY_TAG`) | Proxy tag from @MTProxybot (32 hex characters) | empty |
| `WORKERS` | Number of worker processes (keep `1` with Fake-TLS) | `1` |
| `EXTERNAL_PORT` | The public port used in Telegram links (should match your host port mapping) | `8443` |
| `EXTERNAL_IP` | Public IPv4 for the links and NAT info; auto-detected when empty | empty |
| `INTERNAL_IP` | Container IPv4; auto-detected when empty | empty |
| `CONFIG_REFRESH_INTERVAL` | Seconds between checks for a new Telegram config; `0` disables | `86400` |
| `DEBUG` | `1` enables shell tracing (prints secrets to the log) | `0` |

Any extra arguments after the image name are passed straight to `mtproto-proxy` (see `mtproto-proxy --help`).

---

## 🧰 Quick Commands

Run in background:

```bash
docker compose up -d
```

View logs (and get your connection link):

```bash
docker logs -f mtproto-proxy
```

Local statistics:

```bash
docker exec mtproto-proxy curl -s http://127.0.0.1:8888/stats
```

Health status:

```bash
docker inspect --format '{{.State.Health.Status}}' mtproto-proxy
```

---

## 🔄 Updating

The Telegram configuration updates itself (see above), so you only need to pull a new image for new upstream code or system updates:

```bash
docker compose pull && docker compose up -d
```

The image is rebuilt weekly from the latest upstream `master`. A build is published only if the smoke test passes (the proxy starts and answers its stats endpoint), so a broken upstream commit leaves the previous image in place. To build a specific upstream commit, run the workflow manually with `mtproxy_ref`, or locally: `docker build --build-arg MTPROXY_REF=<sha> ...`.

---

## 🧾 License

MIT License
© 2026 [codinv](https://github.com/codinv) — based on the original MTProxy by Telegram Messenger LLP.
