# Rationale — Why the n8n Implementation Is Built This Way

This document is the **"why"** behind every significant decision in this repository. It is meant to be read alongside the code: [`docker-compose.yml`](docker-compose.yml:1), [`workflows/telegram-ollama-chatbot.json`](workflows/telegram-ollama-chatbot.json:1), and [`workflows/ovh-email-operations.json`](workflows/ovh-email-operations.json:1).

Each section states the **decision**, the **alternatives considered**, and the **reason** it was chosen. Sections tagged **(lesson learned)** capture a mistake we hit and the rule we now follow — most of them revolve around the `if`/guard-block pattern.

---

## A. Networking & deployment

### A.1. n8n is bound to `127.0.0.1:5678`, not `0.0.0.0:5678`
**Decision:** [`docker-compose.yml`](docker-compose.yml:7) publishes the port as `127.0.0.1:5678:5678`.

**Why:** The container is reachable **only from the Mac itself**. The public surface is provided exclusively by the Cloudflare Tunnel (`cloudflared`), which runs on the Mac and reaches n8n over `localhost`. This means:
- No port is opened on the router/firewall.
- The service is invisible on the local LAN.
- A compromised LAN device cannot reach n8n.

**Alternative considered:** binding to `0.0.0.0` and port-forwarding the router. Rejected because it requires a static/public IP (the Mac has a dynamic one, possibly behind CGNAT), exposes the service to the whole LAN, and is a larger attack surface.

### A.2. Cloudflare Tunnel instead of a VPS / reverse proxy / port forwarding
**Decision:** Ingress is an outbound tunnel from `cloudflared` to Cloudflare; the domain is managed by Cloudflare (see [`docs/networking-cloudflare.md`](docs/networking-cloudflare.md)).

**Why:**
- Works with **dynamic IPs and CGNAT** — no inbound connectivity required at all.
- Provides **free automatic TLS**, DDoS mitigation, and a WAF at the edge.
- **Hides the origin IP** of the Mac.
- The catch-all `service: http_status:404` in the tunnel config rejects any unknown hostname, reducing abuse surface.

**Alternative considered:** a small VPS running nginx + Let's Encrypt, or direct port forwarding. Both need a stable public IP and more moving parts; the tunnel is simpler and more secure for a single-user homelab.

### A.3. `N8N_SECURE_COOKIE=false`
**Decision:** [`docker-compose.yml`](docker-compose.yml:11) sets this to `false`.

**Why:** Cloudflare terminates TLS and forwards to n8n as **plain HTTP** (`http://localhost:5678`). With secure cookies enabled, n8n would set the `Secure` flag, and the browser (talking to Cloudflare over HTTPS) would still work — but the *local* hop is HTTP, and more importantly n8n's cookie handling behind an SSL-offloading proxy can break the editor session. Disabling the secure flag lets the session cookie ride the tunnel's encrypted channel reliably.

**Tradeoff / risk:** cookies are not marked `Secure`, so they could in principle be sent over a non-TLS hop. In this design the only non-TLS hop is `localhost` on the Mac, which is trusted; the user-facing connection is always Cloudflare TLS. Acceptable for a single-owner homelab, but it is a deliberate relaxation, not an oversight.

### A.4. `N8N_PROXY_HOP_BY_HOP_HEADERS=true`
**Decision:** [`docker-compose.yml`](docker-compose.yml:12).

**Why:** When n8n sits behind Cloudflare, certain `Hop-by-Hop` headers (e.g. `Connection`, `Keep-Alive`, `Proxy-Authenticate`) must be handled/forwarded correctly or webhook registration and proxy behavior misbehave. Enabling this tells n8n it is behind a proxy that uses these headers.

### A.5. `N8N_EDITOR_BASE_URL` and `WEBHOOK_URL` point to the public HTTPS host
**Decision:** [`docker-compose.yml`](docker-compose.yml:9) and [`docker-compose.yml`](docker-compose.yml:10) set both to `https://n8n.andrianarison.com`.

**Why:** Telegram delivers updates by **HTTP webhook** to a public URL. n8n must know its own public address to (a) build the webhook URL it registers with Telegram and (b) render correct links in the editor. Without these, n8n would register `http://localhost:5678/...` and Telegram could never reach it.

### A.6. `GENERIC_TIMEZONE=Europe/Paris`
**Decision:** [`docker-compose.yml`](docker-compose.yml:13).

**Why:** The user lives in Paris. Every date computation — email "since" filters, "today", and the pre-computed date chips fed to the LLM — must use Paris local day boundaries, not UTC. Setting it globally makes the container's clock and n8n's `$now`/`$today` expressions consistent with the user's intent (e.g. "emails from today" means Paris today).

### A.7. `restart: unless-stopped` + external `n8n_data` volume
**Decision:** [`docker-compose.yml`](docker-compose.yml:5) and [`docker-compose.yml`](docker-compose.yml:15).

**Why:**
- `restart: unless-stopped` auto-recovers n8n after a Mac reboot or a crash, so the Telegram bot stays available without manual intervention.
- The volume is declared `external: true` ([`docker-compose.yml`](docker-compose.yml:18)) so compose never recreates/initializes it — it persists credentials, workflow definitions, execution history, and the tunnel-registered webhook state across container rebuilds. Losing it would mean re-entering credentials and re-registering the Telegram webhook.

### A.8. `image: ...n8n:latest`
**Decision:** [`docker-compose.yml`](docker-compose.yml:3) pins to `latest`.

**Why / tradeoff:** Guarantees the newest node types (e.g. the langchain `agent` v3.1, `toolWorkflow` v2.2) are available. The tradeoff is reproducibility — a future n8n release could change behavior. For a personal, actively maintained instance this is the right call; pinning to a digest would be safer for production multi-user deployments.

---

## B. Chatbot workflow design

See [`docs/workflow-telegram-chatbot.md`](docs/workflow-telegram-chatbot.md) for the node map.

### B.1. Telegram **Trigger** (webhook) rather than polling
**Decision:** The entry node is `n8n-nodes-base.telegramTrigger` with `updates: ["message"]` ([`workflows/telegram-ollama-chatbot.json`](workflows/telegram-ollama-chatbot.json:6)).

**Why:** Webhooks are push-based and **instant**; polling would add latency and waste API calls. `updates: ["message"]` scopes the trigger to ordinary chat messages only — edits, channel posts, and callback queries are ignored, keeping the bot focused and reducing noise.

### B.2. An **AI Agent** orchestrates the LLM, memory, and tools
**Decision:** A langchain `agent` node ([`workflows/telegram-ollama-chatbot.json`](workflows/telegram-ollama-chatbot.json:48]) is the hub, wired to three sub-connections: `ai_languageModel` (Ollama), `ai_memory` (Simple Memory), and `ai_tool` (Read OVH Emails).

**Why:** The agent pattern lets a single LLM call decide *whether* to use the email tool, *how* to call it, and *how* to phrase the answer — without hard-coding intent routing in n8n. This is far more flexible than a fixed "if message contains X then read email" branch, and it degrades gracefully for non-email chit-chat.

### B.3. `promptType: define` with a **pre-computed date block** injected into the user text
**Decision:** The agent's text template ([`workflows/telegram-ollama-chatbot.json`](workflows/telegram-ollama-chatbot.json:40]) computes `Current date`, `last 7 days`, `last 14 days`, `last 30 days`, and `today` in `Europe/Paris` and prepends them to the user's message. The system message ([`workflows/telegram-ollama-chatbot.json`](workflows/telegram-ollama-chatbot.json:42]) **forbids** the agent from asking the user for any date.

**Why — this is the single most important robustness decision:**
- LLMs are notoriously bad at date arithmetic and at knowing "today's" date.
- By computing the values deterministically in n8n (which is timezone-correct and reliable), we **eliminate an entire class of "wrong date range" failures** ("show me last week's emails" returning the wrong window).
- The system message turns those pre-computed values into a hard contract: the agent must use them and must never ask the user for a date. Asking for a date is explicitly defined as a *failure*.

**Alternative considered:** letting the LLM compute dates via its own knowledge or a Code node at runtime. Rejected — non-deterministic and frequently wrong.

### B.4. **Ollama** local model `gemma4:e4b`, `temperature: 0.7`
**Decision:** [`workflows/telegram-ollama-chatbot.json`](workflows/telegram-ollama-chatbot.json:23) uses the local Ollama chat model; [`workflows/telegram-ollama-chatbot.json`](workflows/telegram-ollama-chatbot.json:25) sets `temperature: 0.7`.

**Why:**
- **Privacy & cost:** the model runs on the Mac; no prompt or email content leaves the machine to a third-party LLM API.
- **`temperature: 0.7`** balances coherence (email facts must be accurate) with natural, varied phrasing for a chat assistant.
- Ollama is reached via `host.docker.internal:11434` — the Docker gateway to the Mac host where Ollama listens.

### B.5. **Simple Memory** keyed by `chat.id`, window 10
**Decision:** [`workflows/telegram-ollama-chatbot.json`](workflows/telegram-ollama-chatbot.json:58) sets `sessionKey` to the Telegram `chat.id` (via the `chatId` field promoted by **Extract Chat Context**); [`workflows/telegram-ollama-chatbot.json`](workflows/telegram-ollama-chatbot.json:59) sets `contextWindowLength: 10`.

**Why:**
- **Per-chat isolation:** using `chat.id` as the session key means two different Telegram users (or groups) each get their own conversation history; one chat cannot see another's context.
- **Bounded context:** a sliding window of 10 messages keeps token usage and latency under control while preserving recent context (e.g. "mark *that* one as read" refers to the previous email).
- **Why not a vector store?** Semantic long-term memory would add complexity, embedding cost, and storage for a use case where "the last few messages" is enough. A buffer window is simpler, cheaper, and sufficient.

### B.6. **Read OVH Emails** is a `toolWorkflow` (sub-workflow), not inline IMAP nodes
**Decision:** The agent's tool is `@n8n/n8n-nodes-langchain.toolWorkflow` ([`workflows/telegram-ollama-chatbot.json`](workflows/telegram-ollama-chatbot.json:217]) pointing at workflow `me7ect2HVlIIo4us` ([`workflows/telegram-ollama-chatbot.json`](workflows/telegram-ollama-chatbot.json:98]), with a fully declared input schema ([`workflows/telegram-ollama-chatbot.json`](workflows/telegram-ollama-chatbot.json:104]).

**Why — separation of concerns:**
- The **email logic lives in its own workflow** ([`workflows/ovh-email-operations.json`](workflows/ovh-email-operations.json:1]) that can be tested, versioned, and debugged independently of the chatbot.
- It is **reusable**: any other workflow or agent (or an MCP client, since it is `availableInMCP: true`) can call the same capability.
- The declared schema acts as a **contract** the LLM uses to fill parameters correctly (filters, limits, mark actions).
- Inline IMAP nodes inside the chatbot would have bloated the agent canvas and coupled two concerns that change for different reasons.

### B.7. **Split Long Reply** chunks at 3900 characters on blank lines
**Decision:** A Code node ([`workflows/telegram-ollama-chatbot.json`](workflows/telegram-ollama-chatbot.json:227]) splits the agent output into chunks of at most `MAX = 3900`, breaking only on `\n\n+` boundaries.

**Why:**
- Telegram's `sendMessage` API hard-limits a message to **4096 characters**. Email summaries routinely exceed that.
- Splitting on **blank lines** keeps each email entry intact (an email is never cut mid-way), which matters because the agent may list many emails.
- **3900 < 4096** leaves a safety margin for any encoding overhead.
- The system message tells the agent that long replies are auto-split, so it is explicitly encouraged to include *all* requested emails rather than truncating — the chunker handles length, the agent handles completeness.

### B.8. **Send Reply to Telegram** uses dynamic `chat.id` and plain-text mode
**Decision:** [`workflows/telegram-ollama-chatbot.json`](workflows/telegram-ollama-chatbot.json:74] sets `chatId` from the trigger's `message.chat.id`; [`workflows/telegram-ollama-chatbot.json`](workflows/telegram-ollama-chatbot.json:75] sends `$json.output`; [`workflows/telegram-ollama-chatbot.json`](workflows/telegram-ollama-chatbot.json:79] sets `disable_web_page_preview: true`, `appendAttribution: false`, and `parse_mode: ""`.

**Why:**
- `chatId` is taken per-message from the trigger, so replies always go back to the right chat (user or group) that originated them.
- `parse_mode: ""` (plain text) is deliberate: email subjects/bodies contain characters (`*`, `_`, backticks, `[`) that would break Telegram Markdown/HTML parsing and cause send failures. Plain text is safe for arbitrary email content.
- `disable_web_page_preview: true` avoids ugly link previews in long email lists.
- `appendAttribution: false` keeps replies clean (no "via n8n" footer).

### B.9. `availableInMCP: true` on the chatbot workflow
**Decision:** [`workflows/telegram-ollama-chatbot.json`](workflows/telegram-ollama-chatbot.json:489].

**Why:** Exposes the workflow as an MCP tool so other AI clients/agents in the ecosystem can invoke the assistant, not just Telegram. It is a forward-looking interoperability choice consistent with the email sub-workflow also being MCP-available.

### B.10. Guard node `Check Message Text` rejects non-text input before the LLM **(lesson learned)**
**Decision:** An `if` (v1) node ([`workflows/telegram-ollama-chatbot.json`](workflows/telegram-ollama-chatbot.json:241]) tests `message.text` `isNotEmpty`; non-text messages route to a `Fallback Message` set node ([`workflows/telegram-ollama-chatbot.json`](workflows/telegram-ollama-chatbot.json:262]) instead of the agent.

**Why (lesson learned):** Telegram `message` updates are not always text — photos, stickers, voice notes, documents, and system messages arrive through the same trigger. Feeding those to the agent yields an empty/`undefined` `text` and a confusing or wasted LLM call. A cheap `if` guard at the very entry boundary converts an ambiguous input into a deterministic, friendly reply and saves tokens.
**Rule of thumb:** validate the input *shape* at the boundary before spending any LLM/API budget.

### B.11. `Check Reset Command` handles `/reset` and `/start` deterministically **(lesson learned)**
**Decision:** An `if` (v2.2) node ([`workflows/telegram-ollama-chatbot.json`](workflows/telegram-ollama-chatbot.json:309]) matches `/reset` or `/start` (case-insensitive) and replies via `Reset Memory Reply` ([`workflows/telegram-ollama-chatbot.json`](workflows/telegram-ollama-chatbot.json:324]) without invoking the agent.

**Why (lesson learned):** Control commands should be intercepted *before* the LLM, not described in the system prompt and hoped for. Routing them through an `if` makes behavior predictable, free of token cost, and impossible to confuse with an email intent.
**Rule of thumb:** any command/keyword the user must be able to rely on belongs in an `if` guard, not in prompt instructions.

### B.12. `Extract Chat Context` decouples the memory session key from the trigger node **(lesson learned)**
**Decision:** A Code node ([`workflows/telegram-ollama-chatbot.json`](workflows/telegram-ollama-chatbot.json:338]) copies `message.chat.id` into a top-level `chatId` field; `Simple Memory`'s `sessionKey` now reads `$json.chatId` ([`workflows/telegram-ollama-chatbot.json`](workflows/telegram-ollama-chatbot.json:58]) instead of `$('Telegram Message Received').item.json.message.chat.id`.

**Why (lesson learned):** Originally the memory key reached *back* to the trigger node by name. That couples memory to a specific node's position in the graph — rewiring or inserting nodes upstream silently breaks the session key. Promoting the id to a first-class field at the boundary makes every downstream node self-contained.
**Rule of thumb:** promote cross-node identifiers to top-level fields once, near the entry, rather than re-deriving them from a specific upstream node everywhere.

---

## C. Email sub-workflow design

See [`docs/workflow-ovh-email.md`](docs/workflow-ovh-email.md) for the node map.

### C.1. `executeWorkflowTrigger` with `inputSource: passthrough`
**Decision:** [`workflows/ovh-email-operations.json`](workflows/ovh-email-operations.json:6).

**Why:** This is a **sub-workflow** meant to be called by the chatbot's tool node (and potentially MCP). `passthrough` lets incoming data flow straight into the first processing node without transformation at the boundary.

### C.2. **Parse Input** normalizes both JSON and `key=value` string shapes
**Decision:** A Set node in raw mode ([`workflows/ovh-email-operations.json`](workflows/ovh-email-operations.json:17]) merges a JSON object, and if an `input` string is present, parses either JSON or simple `key=value` pairs (coercing `true`/`false`/numbers).

**Why:** Flexibility at the boundary. The chatbot tool passes a structured object, but the workflow can also be triggered/tested directly with a raw string payload. Coercing booleans/numbers here means downstream nodes receive clean types. `includeOtherFields: true` and `stripBinary: true` ([`workflows/ovh-email-operations.json`](workflows/ovh-email-operations.json:18], [`workflows/ovh-email-operations.json`](workflows/ovh-email-operations.json:20]) keep the payload tidy, and the conversion is done explicitly in the expression rather than relying on auto-type detection.

### C.3. **Route Action** branches on `action === "mark"`
**Decision:** An IF node ([`workflows/ovh-email-operations.json`](workflows/ovh-email-operations.json:41]) sends `mark` to *Set Email Flags* and everything else to *Read Emails*.

**Why:** Two distinct IMAP operations with different required parameters. A single clear branch is easier to reason about and extend (e.g. adding a `delete` action later) than cramming both into one node.

### C.4. **Read Emails** uses the community **IMAP Enhanced** node, not the built-in Email node
**Decision:** [`workflows/ovh-email-operations.json`](workflows/ovh-email-operations.json:91] uses `n8n-nodes-imap-enhanced.imapEnhanced` with `getEmailsList`.

**Why:** The built-in IMAP node lacks the richer **flag-setting** operation (`setEmailFlags`) and the fine-grained filtering this design needs for the "mark as read/flagged/deleted" capability. The enhanced node provides both read-with-filters and write-flags in one consistent credential model (`coreImapAccount`).

### C.5. **Default `since` = last 30 days; default `limit` = 50**
**Decision:** [`workflows/ovh-email-operations.json`](workflows/ovh-email-operations.json:66] defaults `since` to `$today.minus({ days: 30 })`; [`workflows/ovh-email-operations.json`](workflows/ovh-email-operations.json:87] defaults `limit` to `50`.

**Why:** Most email questions are about recent mail, so a 30-day window avoids dumping the entire mailbox (token/performance cost) while still being useful. `limit: 50` bounds the payload; the agent is instructed to request a higher `limit` when the user explicitly wants "all".

### C.6. **Flag filters coerce strings → boolean/`undefined`**
**Decision:** The `emailFlags` expressions ([`workflows/ovh-email-operations.json`](workflows/ovh-email-operations.json:69]) map `'' / undefined / null` → `undefined`, and `'true'`/`true` → `true`, `'false'`/`false` → `false` (for `answered`, `deleted`, `draft`, `flagged`, `seen`; `recent` is fixed to `false`).

**Why:** The tool schema passes everything as **strings** (the `toolWorkflow` schema types are strings). IMAP, however, needs real booleans — and critically, **`undefined` means "do not filter on this flag"**. If we passed the string `'false'`, it is truthy in JS and would wrongly filter. Converting to `undefined` when absent is what makes "show all mail, don't filter by seen" actually work. This is a subtle but essential correctness detail.

### C.7. **`alwaysOutputData: true`** on Read Emails
**Decision:** [`workflows/ovh-email-operations.json`](workflows/ovh-email-operations.json:94].

**Why:** If the mailbox is empty (or filters match nothing), the node still emits an item so *Format Results* runs and the agent receives a clean "0 emails" answer instead of an error that would abort the whole chat turn.

### C.8. **Format Results** produces a compact, LLM-friendly summary
**Decision:** A Code node ([`workflows/ovh-email-operations.json`](workflows/ovh-email-operations.json:100]) maps raw IMAP envelopes into `{ uid, subject, from, date, size, flags, bodyPreview (≤300 chars) }`, plus a `count` and a one-line `summary`.

**Why:**
- The LLM (and the chatbot's system message) expect a **consistent shape**; raw IMAP envelope objects are noisy and inconsistent.
- `count` is surfaced so the agent **always reports the total** ("There are 30 emails"), satisfying the chatbot's output rules.
- `bodyPreview` is truncated to 300 chars to control token usage; the agent can ask for specifics if needed.

### C.9. **Set Email Flags** writes `\Seen` / `\Flagged` / `\Deleted` / `\Answered`
**Decision:** [`workflows/ovh-email-operations.json`](workflows/ovh-email-operations.json:119] maps `markAsRead`/`markFlagged`/`markDeleted`/`markAnswered` to the corresponding IMAP system flags by UID.

**Why:** This is what makes "mark that invoice as read" actually mutate the mailbox. Using UIDs (not sequence numbers) is correct because UIDs are stable across sessions.

### C.10. `callerPolicy: workflowsFromSameOwner`
**Decision:** [`workflows/ovh-email-operations.json`](workflows/ovh-email-operations.json:227].

**Why:** A security boundary. This sub-workflow can mutate a real mailbox, so it should only be invokable by workflows owned by the same n8n owner — not by arbitrary external callers. Combined with `availableInMCP: true` ([`workflows/ovh-email-operations.json`](workflows/ovh-email-operations.json:225]), it stays reusable yet protected.

### C.11. `Validate Action` rejects unsupported actions **(lesson learned)**
**Decision:** An `if` (v2.2) node ([`workflows/ovh-email-operations.json`](workflows/ovh-email-operations.json:135]) allows only `action === "read"` OR `action === "mark"` (combined with `or`); anything else routes to `Invalid Action Error` ([`workflows/ovh-email-operations.json`](workflows/ovh-email-operations.json:168]).

**Why (lesson learned):** Previously the design relied on `Route Action`'s `else` branch to mean "read". A typo like `action: "red"` then silently fell through to a read and returned mail the user never asked for — a confusing, hard-to-debug failure. An explicit **contract guard** at the entry boundary fails *closed* with a clear error instead of defaulting.
**Rule of thumb:** enumerate the allowed values of an enum parameter and reject the rest; never let "unknown" silently become a default branch.

### C.12. `Validate Mark` requires `emailUid` before a mutating call **(lesson learned)**
**Decision:** An `if` (v2.2) node ([`workflows/ovh-email-operations.json`](workflows/ovh-email-operations.json:152]) checks `emailUid` `isNotEmpty` before `Set Email Flags`; missing it routes to `Missing EmailUid Error` ([`workflows/ovh-email-operations.json`](workflows/ovh-email-operations.json:181]).

**Why (lesson learned):** `setEmailFlags` is a **write** operation that needs a UID. Without this guard, a `mark` call with no UID would either fail deep inside the IMAP node (a cryptic error) or, worse, act on nothing/ambiguous input and waste an IMAP round-trip. Validating required parameters *before* the side-effecting node turns a confusing failure into a precise, actionable message.
**Rule of thumb:** for any node that mutates state, validate its required inputs with an `if` guard immediately beforehand and fail with a message the caller can act on.

---

## D. Cross-cutting rationale

### D.1. Two-workflow decomposition (orchestrator vs capability)
The chatbot ([`workflows/telegram-ollama-chatbot.json`](workflows/telegram-ollama-chatbot.json:1]) is the **UX/orchestration** layer; the email workflow ([`workflows/ovh-email-operations.json`](workflows/ovh-email-operations.json:1]) is a **reusable capability**. This follows the single-responsibility principle at the workflow level: each changes for different reasons, can be tested alone, and the email capability can serve future workflows/agents/MCP clients.

### D.2. Local-first / privacy by construction
- LLM inference happens on-device (Ollama) — no prompt or email content is sent to a third-party model API.
- Email is read/written directly via IMAP to OVH — no intermediate email processor.
- The only external transits are (a) Telegram (message content, by nature of the chat UI) and (b) Cloudflare's edge (TLS termination for the webhook), both encrypted.

### D.3. Timezone consistency everywhere
`Europe/Paris` is set at the container level (A.6) and re-asserted in the agent's date expressions (B.3). This prevents the classic bug where "today's emails" is computed in UTC and silently returns the wrong day for a Paris user.

### D.4. Resilience by default
- `restart: unless-stopped` (A.7) and an external persistent volume (A.7) survive reboots.
- `alwaysOutputData` (C.7) prevents empty-result aborts.
- Explicit type coercion (C.6, C.2) prevents the silent truthiness bugs that plague stringly-typed automation.
- **Fail-closed guards** (B.10, B.11, C.11, C.12) keep bad/ambiguous input from reaching the LLM or a mutating IMAP call.

---

## E. Known tradeoffs & risks (so you can decide consciously)

| Decision | Tradeoff / risk | Mitigation |
|----------|-----------------|------------|
| `N8N_SECURE_COOKIE=false` (A.3) | Session cookie not `Secure`-flagged | Only the trusted `localhost` hop is plaintext; user link is Cloudflare TLS |
| `image: latest` (A.8) | Non-reproducible builds | Acceptable for a personal, maintained instance; pin a digest for multi-user prod |
| Memory window = 10 (B.5) | Older context is forgotten | Fine for chat; increase if long threads needed |
| Pre-computed dates assume current year (B.3) | "July 10th" with no year → current year | Documented in system message; matches user intent |
| `callerPolicy: workflowsFromSameOwner` (C.10) | Cannot be called cross-owner | Intentional; relax only if a trusted external caller is needed |
| Plain-text Telegram replies (B.8) | No Markdown formatting | Safer for arbitrary email content; avoids send failures |
| `Reset Memory Reply` is cosmetic (B.11) | Does not hard-clear durable memory | Fine while memory is an in-memory window; add an explicit clear if durable memory is introduced |

---

## F. How to extend this design

- **New capability** (e.g. calendar, notes): build it as its own sub-workflow (like [`workflows/ovh-email-operations.json`](workflows/ovh-email-operations.json:1]), expose it as a `toolWorkflow` in the agent, and add a tool description + system-message guidance — mirroring B.6.
- **New LLM**: swap the Ollama node (B.4) for another langchain model node; the rest of the agent is model-agnostic.
- **Multi-user hardening**: pin the image digest (A.8), reconsider `N8N_SECURE_COOKIE` with a proper TLS-terminating reverse proxy, and tighten `callerPolicy` (C.10).
- **New `action` in the email workflow**: add a branch in `Route Action` (C.3), extend the allowed list in `Validate Action` (C.11), and add a `Validate Mark`-style guard (C.12) if the new action needs its own required parameter.

---

## G. Lessons learned — the `if`/guard-block pattern

The biggest class of bugs we hit came from **trusting the LLM or a default branch** at a boundary. Every one was fixed the same way: insert a cheap `if` guard that validates input and fails *closed* (with a clear error or a safe default) before any expensive or side-effecting step. The pattern, distilled:

1. **Validate input shape at the boundary (B.10).** Non-text Telegram messages used to reach the LLM with `undefined` text. A single `isNotEmpty` `if` now routes them to a friendly fallback — no token wasted.
2. **Intercept commands with `if`, not prompts (B.11).** `/reset` and `/start` are handled by an `if` *before* the agent, so they are reliable and free.
3. **Promote cross-node identifiers once (B.12).** `chatId` is extracted into a top-level field at the entry, so the memory key no longer depends on a specific upstream node's name/position.
4. **Enumerate enums and reject the rest (C.11).** A typo'd `action` used to silently default to "read". Now `Validate Action` allows only `read`/`mark` and errors otherwise.
5. **Validate required params before mutating (C.12).** `mark` without `emailUid` used to fail deep in IMAP; now `Validate Mark` rejects it up front with an actionable message.

**General rule:** *any* node that costs money (LLM/API call) or mutates state (IMAP write, DB insert, webhook POST) should be preceded by an `if` guard that checks its preconditions. The guard is nearly free; the failure it prevents is expensive and confusing.
