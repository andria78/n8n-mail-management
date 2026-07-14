# Networking & Cloudflare Tunnel — Rationale and Setup

This document explains **why** the n8n instance is exposed the way it is, and documents the Cloudflare Tunnel + OVH→Cloudflare DNS migration that makes the Telegram webhook reachable. It complements the high-level view in [`docs/README.md`](docs/README.md) and the decision list in [`docs/rationale.md`](docs/rationale.md) (sections A.1–A.5).

---

## 1. The problem being solved

n8n needs a **public HTTPS endpoint** so that:

1. **Telegram can push webhooks** to it (the Telegram Trigger registers a callback URL with Telegram's servers).
2. The owner can open the n8n editor from anywhere.

But the host is a **residential Mac**:
- It has a **dynamic public IP** (changes on reconnect).
- It may sit behind **CGNAT** (no publicly routable IP at all).
- Opening inbound ports on the ISP router is undesirable (attack surface, LAN exposure) and often impossible under CGNAT.

A Cloudflare Tunnel solves all of these with **zero inbound connectivity**.

---

## 2. How the tunnel works (and why it needs no open port)

```
 Telegram / Browser
        │  HTTPS to n8n.andrianarison.com
        ▼
 Cloudflare edge  ────(encrypted, outbound)────▶  cloudflared  ──▶  n8n (127.0.0.1:5678)
 (TLS, WAF, DDoS)                                  (on the Mac)      (Docker container)
```

- `cloudflared` (running on the Mac) opens an **outbound** connection to Cloudflare and keeps it open.
- Cloudflare routes `n8n.andrianarison.com` traffic **down** that tunnel to `http://localhost:5678`.
- Because the connection is initiated *from* the Mac *to* Cloudflare, **no router port forwarding is required**, and it works regardless of dynamic IP or CGNAT.

This is why [`docker-compose.yml`](docker-compose.yml:7) binds n8n to `127.0.0.1:5678` — only the local `cloudflared` process needs to reach it.

---

## 3. Why the domain had to move OVH → Cloudflare

Cloudflare Tunnel requires the domain's **DNS to be managed by Cloudflare**, because:

- The tunnel is addressed by a special CNAME target `<tunnel-id>.cfargotunnel.com`.
- Cloudflare must own the zone to create that record and to apply its proxy/WAF in front of the tunnel.

OVH, as the original registrar/DNS host, cannot proxy traffic into a Cloudflare Tunnel. Hence the migration documented in [`plans/guide-ovh-cloudflare.md`](plans/guide-ovh-cloudflare.md).

### 3.1 Why DNSSEC must be disabled at OVH *first*
[`plans/guide-ovh-cloudflare.md`](plans/guide-ovh-cloudflare.md:35) instructs disabling DNSSEC at OVH **before** changing nameservers.

**Why:** DNSSEC signs the zone with OVH's keys. If you point the domain at Cloudflare's nameservers while OVH's DS records (the secure delegation) are still published in the parent zone, resolvers will see a **broken chain of trust** and treat the domain as Bogus/INSECURE — the domain can go **dark** (unresolvable) until the mismatch is fixed. Disabling DNSSEC at OVH first removes the DS records so the handoff to Cloudflare is clean.

### 3.2 Why emails and the website keep working
[`plans/guide-ovh-cloudflare.md`](plans/guide-ovh-cloudflare.md:7) notes Cloudflare **imports the existing DNS records** (MX, A, etc.) during the "Add a Site" step. As long as the MX records are copied, **email delivery is unaffected**. There may be a brief interruption during DNS propagation, after which everything returns to normal.

### 3.3 The catch-all `http_status:404`
The tunnel config ([`plans/telegram-ollama-chatbot-workflow.md`](plans/telegram-ollama-chatbot-workflow.md:86)) ends with:
```yaml
ingress:
  - hostname: n8n.andrianarison.com
    service: http://localhost:5678
  - service: http_status:404
```
**Why the final `404` rule:** any request to the tunnel for a hostname other than `n8n.andrianarison.com` returns 404. This prevents the tunnel from being abused as a generic proxy and limits it to the single intended service.

---

## 4. `docker-compose.yml` environment variables — explained

| Variable | Value | Why it is set ([`docker-compose.yml`](docker-compose.yml:1)) |
|----------|-------|----------------------------------------|
| `N8N_EDITOR_BASE_URL` | `https://n8n.andrianarison.com` | Tells n8n its public editor URL so links/redirects in the UI are correct. |
| `WEBHOOK_URL` | `https://n8n.andrianarison.com/` | The base URL n8n uses when **registering webhooks** with Telegram. Without this, it would register `localhost`, which Telegram cannot reach. |
| `N8N_SECURE_COOKIE` | `false` | Cloudflare terminates TLS and forwards to n8n as plain HTTP on localhost; relaxing the Secure flag keeps the editor session stable behind the SSL-offloading proxy. (See tradeoff in [`docs/rationale.md`](docs/rationale.md) A.3.) |
| `N8N_PROXY_HOP_BY_HOP_HEADERS` | `true` | Correctly handles hop-by-hop headers when n8n is behind Cloudflare's proxy. |
| `GENERIC_TIMEZONE` | `Europe/Paris` | All date math (email `since` filters, "today") uses Paris local time, matching the user's intent. |

### Port & volume
- `127.0.0.1:5678:5678` ([`docker-compose.yml`](docker-compose.yml:7)) — localhost-only, reached by the tunnel.
- `restart: unless-stopped` ([`docker-compose.yml`](docker-compose.yml:5)) — auto-recover on reboot/crash.
- `n8n_data` external volume ([`docker-compose.yml`](docker-compose.yml:15), [`docker-compose.yml`](docker-compose.yml:18)) — persists credentials, workflows, execution history, and webhook registration across container recreations.

---

## 5. Operational notes

### 5.1 Starting the stack
```bash
cd /Volumes/Public/Hobbies/VibeCoding/n8nMailManagement
docker compose up -d
cloudflared tunnel run n8n-tunnel &   # or: cloudflared service install
```
([`plans/telegram-ollama-chatbot-workflow.md`](plans/telegram-ollama-chatbot-workflow.md:110))

### 5.2 Webhook re-registration
When the tunnel (or n8n) restarts, n8n re-registers the Telegram webhook using `WEBHOOK_URL`. Because the public URL is stable (`n8n.andrianarison.com`), no manual reconfiguration is needed — but the **Telegram Trigger node must be active** for the registration to occur.

### 5.3 Verifying reachability
- `https://n8n.andrianarison.com` should show the n8n editor.
- In n8n, the **Telegram Ollama Chatbot** workflow toggle must be **Active** ([`workflows/telegram-ollama-chatbot.json`](workflows/telegram-ollama-chatbot.json:140)) for the webhook to accept messages.

### 5.4 Security posture summary
- **No open inbound ports** on the router/LAN.
- **Origin IP hidden** behind Cloudflare.
- **Free automatic TLS** + DDoS/WAF at the edge.
- Only `localhost` (trusted) sees unencrypted n8n traffic; the user-facing leg is always Cloudflare TLS.
- Unknown hostnames hitting the tunnel get `404`.
