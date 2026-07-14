# n8n Mail Management — Implementation Documentation

This documentation explains **what** the n8n implementation in this repository does and, more importantly, **why** it is built the way it is. It is the single source of truth for the architecture, the networking model, and the two workflows that make up the system.

The companion guides in [`plans/`](plans/telegram-ollama-chatbot-workflow.md) describe the *original build steps*; this `docs/` folder explains the *resulting design and its rationale*.

---

## 1. What this system is

A self-hosted, privacy-first **Telegram chatbot** that lets you talk to your OVH/Outlook email from Telegram, powered by a **locally running LLM (Ollama)** — no third-party LLM API, no cloud email processing.

You send a message in Telegram such as *"show my unread emails"* or *"mark the invoice from Orange as read"*, and the bot reads/manages your mailbox via IMAP and replies in natural language.

### Components at a glance

| Component | File | Role |
|-----------|------|------|
| n8n runtime | [`docker-compose.yml`](docker-compose.yml:1) | Containerized n8n, bound to localhost, exposed via Cloudflare Tunnel |
| Chatbot workflow | [`workflows/telegram-ollama-chatbot.json`](workflows/telegram-ollama-chatbot.json:1) | Telegram → AI Agent (Ollama) → Telegram, with email tool |
| Email sub-workflow | [`workflows/ovh-email-operations.json`](workflows/ovh-email-operations.json:1) | Reusable IMAP read/mark capability, called as a tool |
| DNS migration guide | [`plans/guide-ovh-cloudflare.md`](plans/guide-ovh-cloudflare.md:1) | How the domain was moved OVH → Cloudflare for the tunnel |
| Build plan | [`plans/telegram-ollama-chatbot-workflow.md`](plans/telegram-ollama-chatbot-workflow.md:1) | Original step-by-step build notes |

---

## 2. System architecture

### 2.1 Network topology

```
┌──────────────┐     HTTPS      ┌──────────────────┐
│  Telegram    │ ─────────────▶ │ Cloudflare edge  │
│  (user chat) │                │ n8n.andrianarison│
└──────────────┘                │ .com  (TLS, WAF, │
        ▲                       │  DDoS protection)│
        │ HTTPS webhook         └────────┬─────────┘
        │                                │ Cloudflare Tunnel
        │                        (encrypted, no open port)
        │                                │
        │                       ┌────────▼─────────┐
        │                       │  cloudflared     │  runs on the Mac
        │                       │  (localhost:5678)│
        │                       └────────┬─────────┘
        │                                │ http://127.0.0.1:5678
        │                       ┌────────▼─────────┐
        │                       │  n8n container   │
        │                       │  (Docker, Mac)   │
        │                       └────────┬─────────┘
        │              ┌────────────────┼────────────────┐
        │              │                │                 │
        │     ┌────────▼─────┐  ┌──────▼──────┐  ┌──────▼────────┐
        │     │ Ollama       │  │ OVH Email   │  │ Telegram API  │
        │     │ (local LLM)  │  │ (IMAP)      │  │ (reply send)  │
        │     │ :11434       │  │ mail.ovh.net│  │                │
        │     └──────────────┘  └─────────────┘  └───────────────┘
```

Key property: **the Mac exposes no inbound port to the internet.** All ingress is an *outbound* connection from `cloudflared` to Cloudflare. This is why a residential Mac with a dynamic IP and possibly CGNAT can still host a publicly reachable webhook.

### 2.2 Workflow topology

```
 Telegram Trigger                 AI Agent (langchain)
 (webhook)                ─────▶  ├─ Ollama Chat Model  (gemma4:e4b, local)
   │                               ├─ Simple Memory       (per chat.id, window 10)
   │                               └─ Read OVH Emails     (toolWorkflow → sub-wf)
   │                                        │
   ▼                                        ▼
 Split Long Reply                ┌──────────────────────────┐
 (chunk ≤ 3900 chars)           │ OVH Email Operations wf  │
   │                             │  read / mark via IMAP    │
   ▼                             └──────────────────────────┘
 Send Reply to Telegram
```

The chatbot workflow is the **orchestrator/UX layer**; the email workflow is a **capability layer** it calls as a tool. See [`docs/workflow-telegram-chatbot.md`](docs/workflow-telegram-chatbot.md) and [`docs/workflow-ovh-email.md`](docs/workflow-ovh-email.md).

---

## 3. Documentation map

| Document | What it covers |
|----------|----------------|
| **[`docs/rationale.md`](docs/rationale.md)** | The centerpiece: *why* every major decision was made (networking, memory, date handling, splitting, tool pattern, IMAP coercion, etc.) |
| **[`docs/networking-cloudflare.md`](docs/networking-cloudflare.md)** | Cloudflare Tunnel, OVH→Cloudflare DNS migration, and every `docker-compose.yml` environment variable explained |
| **[`docs/workflow-telegram-chatbot.md`](docs/workflow-telegram-chatbot.md)** | Node-by-node walkthrough of the chatbot workflow |
| **[`docs/workflow-ovh-email.md`](docs/workflow-ovh-email.md)** | Node-by-node walkthrough of the email sub-workflow |

---

## 4. Design principles (summary)

These principles recur throughout the implementation and are detailed in [`docs/rationale.md`](docs/rationale.md):

1. **Local-first / privacy** — LLM runs on your hardware (Ollama); email is read directly via IMAP. No OpenAI/Anthropic API, no email sent to a third party for processing.
2. **No open inbound ports** — Cloudflare Tunnel provides public HTTPS without router/firewall changes, surviving dynamic IPs and CGNAT.
3. **Deterministic date handling** — all "today / last 7 / 14 / 30 days" values are pre-computed in n8n expressions (timezone-aware) and injected into the prompt, removing the LLM's weakest spot (date math).
4. **Separation of concerns** — the email capability is a standalone, reusable, MCP-exposed sub-workflow rather than inline nodes, so it can be tested, versioned, and reused independently.
5. **Resilience by default** — `restart: unless-stopped`, an external persistent volume, `alwaysOutputData`, and explicit type coercion prevent silent failures.
6. **Platform limits respected** — Telegram's 4096-char message cap is handled by a chunking node that splits on email boundaries.

---

## 5. Quick reference

- **Public URL:** `https://n8n.andrianarison.com`
- **Local n8n:** `http://127.0.0.1:5678`
- **Local LLM:** `http://host.docker.internal:11434` (Ollama on the Mac host)
- **Chatbot workflow ID:** `E6zR3WkUfXjCdeE6`
- **Email sub-workflow ID:** `me7ect2HVlIIo4us`
- **Timezone:** `Europe/Paris` (used consistently everywhere)
