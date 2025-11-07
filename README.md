# 🛰️ MTProto Proxy (Docker, ubuntu:24.04)

A lightweight **Telegram MTProto Proxy** built on **ubuntu:24.04**.
Fully containerized, minimal, and production-ready.

---

## 🚀 Description

This Docker image provides a simple and secure way to run a Telegram MTProto proxy server.
Based on the official [TelegramMessenger/MTProxy](https://github.com/TelegramMessenger/MTProxy) source.
The image includes `curl`, `wget`, and `iproute2` for IP detection and network setup.

---

## 🐳 Docker Compose Example

```yaml
# docker-compose.yml
version: "3.8"
services:
  mtproto:
    container_name: mtproto-proxy
    image: ghcr.io/codinv/mtproto
    restart: unless-stopped
    network_mode: bridge
    ports:
      - "8443:8443"   # you can change this to "443:443", "5000:5000", etc. — just make sure to set the same port in PORT= below
    environment:
      - SECRET=auto    # or specify your own 32-character hex secret
      - PORT=8443
      - WORKERS=2
```

---

## 🔑 Generate Your SECRET

Run this command to create your own 32-character hexadecimal secret:

```bash
head -c 16 /dev/urandom | xxd -ps
```

---

## 🌐 Connect via Telegram

If your server IP is `1.2.3.4`, use one of these links:

```
tg://proxy?server=1.2.3.4&port=8443&secret=abcd1234abcd1234abcd1234abcd1234
```

or

```
https://t.me/proxy?server=1.2.3.4&port=8443&secret=abcd1234abcd1234abcd1234abcd1234
```

> ⚠️ **Note:** If you change the port in your `docker-compose.yml`, update it in the links above.

---

## ⚙️ Environment Variables

| Variable  | Description                                                             | Default |
| --------- | ----------------------------------------------------------------------- | ------- |
| `SECRET`  | 32-char hex key for encryption (`auto` will generate one automatically) | `auto`  |
| `PORT`    | Listening port inside the container                                     | `8443`  |
| `WORKERS` | Number of worker threads                                                | `2`     |

---

## 🧰 Quick Commands

Run in background:

```bash
docker compose up -d
```

View logs:

```bash
docker logs -f mtproto-proxy
```

---

## 🧾 License

MIT License
© 2025 [codinv](https://github.com/codinv) — based on the original MTProxy by Telegram Messenger LLP.

---
