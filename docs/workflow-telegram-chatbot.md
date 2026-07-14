# Workflow: Telegram Ollama Chatbot

**File:** [`workflows/telegram-ollama-chatbot.json`](workflows/telegram-ollama-chatbot.json:1)
**Status:** `active: true` ([`workflows/telegram-ollama-chatbot.json`](workflows/telegram-ollama-chatbot.json:485))
**Role:** Orchestration / UX layer. Receives Telegram messages, guards against non-text/command inputs, reasons with a local LLM, can call the email sub-workflow as a tool, and replies in Telegram.

This is the **parent** workflow. The email capability it uses lives in [`workflows/ovh-email-operations.json`](workflows/ovh-email-operations.json:1) (see [`docs/workflow-ovh-email.md`](docs/workflow-ovh-email.md)). The *why* behind each node is in [`docs/rationale.md`](docs/rationale.md) sections B.1–B.12.

---

## 1. Node map

```
Telegram Message Received (trigger, webhook)
        │  main
        ▼
Check Message Text (if v1: $json.message.text is not empty?)
   ├─ true  ─────────────▶ Check Reset Command (if v2.2: text contains /reset or /start?)
   │                          ├─ true  ─▶ Reset Memory Reply (set) ─┐
   │                          └─ false ─▶ Extract Chat Context (code) ─┐
   └─ false ─────────────▶ Fallback Message (set) ──────────────────┤
                                                                      │
AI Assistant with Email (langchain agent) ◀──────────────────────────┘
    ├── ai_languageModel ──▶ Ollama (gemma4:e4b, local)
    ├── ai_memory        ──▶ Simple Memory (per chat.id, window 10)
    └── ai_tool         ──▶ Read OVH Emails (toolWorkflow → sub-wf)
        │  main
        ▼
Split Long Reply (code, chunk ≤ 3900)
        │  main
        ▼
Send Reply to Telegram (sendMessage)
```

Connections: [`workflows/telegram-ollama-chatbot.json`](workflows/telegram-ollama-chatbot.json:346).

---

## 2. Node-by-node

### 2.1 Telegram Message Received — `telegramTrigger`
- **Type/version:** `n8n-nodes-base.telegramTrigger` v1.3 ([`workflows/telegram-ollama-chatbot.json`](workflows/telegram-ollama-chatbot.json:13))
- **Config:** `updates: ["message"]` ([`workflows/telegram-ollama-chatbot.json`](workflows/telegram-ollama-chatbot.json:6)); `webhookId: "wh-telegram-001"` ([`workflows/telegram-ollama-chatbot.json`](workflows/telegram-ollama-chatbot.json:19))
- **Why:** Webhook (push) trigger for instant delivery; scoped to `message` updates only (no edits/callbacks/channel posts). The fixed `webhookId` keeps the registered Telegram callback stable across edits.

### 2.2 Check Message Text — `if` (v1)
- **Type/version:** `n8n-nodes-base.if` v1 ([`workflows/telegram-ollama-chatbot.json`](workflows/telegram-ollama-chatbot.json:241])
- **Config:** single string condition `message.text` `isNotEmpty` ([`workflows/telegram-ollama-chatbot.json`](workflows/telegram-ollama-chatbot.json:252])
- **Why:** The agent and memory nodes expect a text payload. Photos, stickers, voice notes, documents, or any non-text `message` would otherwise reach the LLM with no `text` field and produce a confusing/empty answer. This guard routes anything without text to a friendly **Fallback Message** instead of burning an LLM call. See [`docs/rationale.md`](docs/rationale.md) B.10.

### 2.3 Fallback Message — `set` (raw)
- **Type/version:** `n8n-nodes-base.set` v3.4 ([`workflows/telegram-ollama-chatbot.json`](workflows/telegram-ollama-chatbot.json:262])
- **Config:** `mode: raw`; `jsonOutput: { output: "Désolé, je ne peux traiter que les messages texte pour le moment." }` ([`workflows/telegram-ollama-chatbot.json`](workflows/telegram-ollama-chatbot.json:270])
- **Why:** A graceful, deterministic reply for non-text messages. It emits the same `output` shape the agent would, so it flows straight into **Send Reply to Telegram** without special-casing. See [`docs/rationale.md`](docs/rationale.md) B.10.

### 2.4 Check Reset Command — `if` (v2.2)
- **Type/version:** `n8n-nodes-base.if` v2.2 ([`workflows/telegram-ollama-chatbot.json`](workflows/telegram-ollama-chatbot.json:309])
- **Config:** two string `contains` conditions on `message.text.toLowerCase()` — `/reset` and `/start` — combined with `combinator: or` ([`workflows/telegram-ollama-chatbot.json`](workflows/telegram-ollama-chatbot.json:291], [`workflows/telegram-ollama-chatbot.json`](workflows/telegram-ollama-chatbot.json:300])
- **Why:** Gives the user an explicit, predictable way to clear conversation memory. Routing this *before* the agent means the command is handled deterministically (no LLM guesswork, no token cost) and never gets forwarded to the email tool. See [`docs/rationale.md`](docs/rationale.md) B.11.

### 2.5 Reset Memory Reply — `set` (raw)
- **Type/version:** `n8n-nodes-base.set` v3.4 ([`workflows/telegram-ollama-chatbot.json`](workflows/telegram-ollama-chatbot.json:324])
- **Config:** `mode: raw`; `jsonOutput: { output: "🔄 Session réinitialisée ! ..." }` ([`workflows/telegram-ollama-chatbot.json`](workflows/telegram-ollama-chatbot.json:319])
- **Why:** Confirms the reset in plain text. Note: the actual memory clearing is implicit — because **Simple Memory** is keyed by `chat.id` and n8n's buffer window is in-memory per session, sending a fresh reply without carrying prior context effectively starts a new window. (If durable memory is later added, this node is where an explicit clear call would go.) See [`docs/rationale.md`](docs/rationale.md) B.11.

### 2.6 Extract Chat Context — `code` (v2)
- **Type/version:** `n8n-nodes-base.code` v2 ([`workflows/telegram-ollama-chatbot.json`](workflows/telegram-ollama-chatbot.json:338])
- **Config:** `jsCode` returns `{ ...$json, chatId: $json.message.chat.id }` ([`workflows/telegram-ollama-chatbot.json`](workflows/telegram-ollama-chatbot.json:334])
- **Why:** Promotes `chat.id` into a top-level `chatId` field so downstream nodes (notably **Simple Memory**'s `sessionKey`) can read it via `$json.chatId` instead of reaching back to the trigger node. This decouples memory from the trigger's position in the graph and makes the session key robust to future rewiring. See [`docs/rationale.md`](docs/rationale.md) B.12.

### 2.7 AI Assistant with Email — `agent` (langchain)
- **Type/version:** `@n8n/n8n-nodes-langchain.agent` v3.1 ([`workflows/telegram-ollama-chatbot.json`](workflows/telegram-ollama-chatbot.json:48])
- **`promptType: define`** ([`workflows/telegram-ollama-chatbot.json`](workflows/telegram-ollama-chatbot.json:39]) with a **user-text template** that pre-computes dates ([`workflows/telegram-ollama-chatbot.json`](workflows/telegram-ollama-chatbot.json:40]) and a **system message** ([`workflows/telegram-ollama-chatbot.json`](workflows/telegram-ollama-chatbot.json:42]).
- **`enableStreaming: false`** ([`workflows/telegram-ollama-chatbot.json`](workflows/telegram-ollama-chatbot.json:43]) — the full answer is produced, then split and sent; streaming is unnecessary given the chunker.
- **Why:** The agent is the reasoning hub. The date block injected into the user text is the key robustness trick — see [`docs/rationale.md`](docs/rationale.md) B.3. The system message defines tool usage, date-handling rules, and output rules (always report total count, list all when asked, split-safe).

### 2.8 Ollama — `lmChatOllama`
- **Type/version:** `@n8n/n8n-nodes-langchain.lmChatOllama` v1 ([`workflows/telegram-ollama-chatbot.json`](workflows/telegram-ollama-chatbot.json:30])
- **Config:** `model: "gemma4:e4b"` ([`workflows/telegram-ollama-chatbot.json`](workflows/telegram-ollama-chatbot.json:23]); `options.temperature: 0.7` ([`workflows/telegram-ollama-chatbot.json`](workflows/telegram-ollama-chatbot.json:25])
- **Why:** Local, private, free inference. `temperature: 0.7` balances factual accuracy (email data) with natural phrasing. Reached via `host.docker.internal:11434` (Ollama on the Mac host).

### 2.9 Simple Memory — `memoryBufferWindow`
- **Type/version:** `@n8n/n8n-nodes-langchain.memoryBufferWindow` v1.4 ([`workflows/telegram-ollama-chatbot.json`](workflows/telegram-ollama-chatbot.json:63])
- **Config:** `sessionIdType: customKey`; `sessionKey: ={{ $json.chatId }}` ([`workflows/telegram-ollama-chatbot.json`](workflows/telegram-ollama-chatbot.json:58]); `contextWindowLength: 10` ([`workflows/telegram-ollama-chatbot.json`](workflows/telegram-ollama-chatbot.json:59])
- **Why:** Per-chat conversation isolation + bounded recent context. The key now reads `$json.chatId` (populated by **Extract Chat Context**) rather than reaching back to the trigger node — see [`docs/rationale.md`](docs/rationale.md) B.5 and B.12.

### 2.10 Read OVH Emails — `toolWorkflow` (the email tool)
- **Type/version:** `@n8n/n8n-nodes-langchain.toolWorkflow` v2.2 ([`workflows/telegram-ollama-chatbot.json`](workflows/telegram-ollama-chatbot.json:217])
- **Config:** `workflowId: me7ect2HVlIIo4us` ([`workflows/telegram-ollama-chatbot.json`](workflows/telegram-ollama-chatbot.json:98]); full input schema declared ([`workflows/telegram-ollama-chatbot.json`](workflows/telegram-ollama-chatbot.json:104]); `description` tells the LLM when/how to use it ([`workflows/telegram-ollama-chatbot.json`](workflows/telegram-ollama-chatbot.json:94]); `attemptToConvertTypes: false` and `convertFieldsToString: false` ([`workflows/telegram-ollama-chatbot.json`](workflows/telegram-ollama-chatbot.json:211], [`workflows/telegram-ollama-chatbot.json`](workflows/telegram-ollama-chatbot.json:212]).
- **Why:** Calls the standalone email sub-workflow as a tool — separation of concerns + reuse + a clear contract for the LLM. See [`docs/rationale.md`](docs/rationale.md) B.6 and [`docs/workflow-ovh-email.md`](docs/workflow-ovh-email.md).

### 2.11 Split Long Reply — `code`
- **Type/version:** `n8n-nodes-base.code` v2 ([`workflows/telegram-ollama-chatbot.json`](workflows/telegram-ollama-chatbot.json:231])
- **Config:** `MAX = 3900` ([`workflows/telegram-ollama-chatbot.json`](workflows/telegram-ollama-chatbot.json:227]); splits on `\n\n+` (blank lines) so email entries stay intact; emits `chunkIndex`/`chunkTotal`.
- **Why:** Telegram caps messages at 4096 chars; splitting on email boundaries at 3900 keeps entries whole with safety margin. See [`docs/rationale.md`](docs/rationale.md) B.7.

### 2.12 Send Reply to Telegram — `telegram` (sendMessage)
- **Type/version:** `n8n-nodes-base.telegram` v1.2 ([`workflows/telegram-ollama-chatbot.json`](workflows/telegram-ollama-chatbot.json:84])
- **Config:** `chatId: ={{ $('Telegram Message Received').item.json.message.chat.id }}` ([`workflows/telegram-ollama-chatbot.json`](workflows/telegram-ollama-chatbot.json:74]); `text: ={{ $json.output }}` ([`workflows/telegram-ollama-chatbot.json`](workflows/telegram-ollama-chatbot.json:75]); `disable_web_page_preview: true`, `appendAttribution: false`, `parse_mode: ""` ([`workflows/telegram-ollama-chatbot.json`](workflows/telegram-ollama-chatbot.json:79]).
- **Why:** Replies go to the originating chat; plain-text mode avoids Markdown/HTML parse failures on email content. See [`docs/rationale.md`](docs/rationale.md) B.8.

---

## 3. Workflow-level settings

| Setting | Value | Source | Why |
|---------|-------|--------|-----|
| `executionOrder` | `v1` | [`workflows/telegram-ollama-chatbot.json`](workflows/telegram-ollama-chatbot.json:487] | Modern, predictable node execution order. |
| `binaryMode` | `separate` | [`workflows/telegram-ollama-chatbot.json`](workflows/telegram-ollama-chatbot.json:488] | Keeps binary data separate from JSON (not heavily used here, but safe default). |
| `availableInMCP` | `true` | [`workflows/telegram-ollama-chatbot.json`](workflows/telegram-ollama-chatbot.json:489] | Exposes the assistant as an MCP tool for other clients/agents. |

---

## 4. End-to-end flow (example: "show my unread emails")

1. Telegram pushes a `message` update → **Telegram Message Received** fires.
2. **Check Message Text** verifies `message.text` is present. If not → **Fallback Message** → **Send Reply to Telegram** (no LLM call).
3. **Check Reset Command** tests for `/reset` or `/start`. If matched → **Reset Memory Reply** → **Send Reply to Telegram** (no LLM call).
4. Otherwise **Extract Chat Context** promotes `chat.id` to `chatId`, then **AI Assistant with Email** builds the prompt (with pre-computed Paris dates) and, recognizing an email intent, calls **Read OVH Emails** → sub-workflow `me7ect2HVlIIo4us` with `seen=false`.
5. The sub-workflow returns a formatted list + `count`.
6. The agent writes a natural-language reply.
7. **Split Long Reply** chunks it if needed (≤3900 chars).
8. **Send Reply to Telegram** posts it back to the same `chat.id`.

---

## 5. Failure modes & notes
- If Ollama is down, the agent node errors (no LLM). The workflow has no error workflow configured — for a personal bot this is acceptable, but adding one is recommended (see [`docs/rationale.md`](docs/rationale.md) E).
- `enableStreaming: false` means the user waits for the full answer; acceptable because the chunker still delivers long results in multiple messages.
- The fixed `webhookId` ([`workflows/telegram-ollama-chatbot.json`](workflows/telegram-ollama-chatbot.json:19]) ensures Telegram's registered callback URL is stable across workflow edits.
- The two guard `if` nodes (**Check Message Text**, **Check Reset Command**) keep non-text and command inputs out of the LLM, saving tokens and avoiding confusing answers — see [`docs/rationale.md`](docs/rationale.md) B.10–B.11.
- **Simple Memory**'s `sessionKey` reads `$json.chatId` (set by **Extract Chat Context**), not the trigger node directly, so the memory wiring survives graph rewiring — see [`docs/rationale.md`](docs/rationale.md) B.12.
