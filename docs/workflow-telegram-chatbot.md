# Workflow: Telegram Ollama Chatbot

**File:** [`workflows/telegram-ollama-chatbot.json`](workflows/telegram-ollama-chatbot.json:1)
**Status:** `active: true` ([`workflows/telegram-ollama-chatbot.json`](workflows/telegram-ollama-chatbot.json:140))
**Role:** Orchestration / UX layer. Receives Telegram messages, reasons with a local LLM, can call the email sub-workflow as a tool, and replies in Telegram.

This is the **parent** workflow. The email capability it uses lives in [`workflows/ovh-email-operations.json`](workflows/ovh-email-operations.json:1) (see [`docs/workflow-ovh-email.md`](docs/workflow-ovh-email.md)). The *why* behind each node is in [`docs/rationale.md`](docs/rationale.md) sections B.1–B.9.

---

## 1. Node map

```
Telegram Message Received (trigger, webhook)
        │  main
        ▼
AI Assistant with Email (langchain agent)
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

Connections: [`workflows/telegram-ollama-chatbot.json`](workflows/telegram-ollama-chatbot.json:118).

---

## 2. Node-by-node

### 2.1 Telegram Message Received — `telegramTrigger`
- **Type/version:** `n8n-nodes-base.telegramTrigger` v1.3 ([`workflows/telegram-ollama-chatbot.json`](workflows/telegram-ollama-chatbot.json:11))
- **Config:** `updates: ["message"]` ([`workflows/telegram-ollama-chatbot.json`](workflows/telegram-ollama-chatbot.json:6)); `webhookId: "wh-telegram-001"` ([`workflows/telegram-ollama-chatbot.json`](workflows/telegram-ollama-chatbot.json:14))
- **Why:** Webhook (push) trigger for instant delivery; scoped to `message` updates only (no edits/callbacks/channel posts). The fixed `webhookId` keeps the registered Telegram callback stable across edits.

### 2.2 AI Assistant with Email — `agent` (langchain)
- **Type/version:** `@n8n/n8n-nodes-langchain.agent` v3.1 ([`workflows/telegram-ollama-chatbot.json`](workflows/telegram-ollama-chatbot.json:38))
- **`promptType: define`** ([`workflows/telegram-ollama-chatbot.json`](workflows/telegram-ollama-chatbot.json:29)) with a **user-text template** that pre-computes dates ([`workflows/telegram-ollama-chatbot.json`](workflows/telegram-ollama-chatbot.json:30)) and a **system message** ([`workflows/telegram-ollama-chatbot.json`](workflows/telegram-ollama-chatbot.json:32)).
- **`enableStreaming: false`** ([`workflows/telegram-ollama-chatbot.json`](workflows/telegram-ollama-chatbot.json:33)) — the full answer is produced, then split and sent; streaming is unnecessary given the chunker.
- **Why:** The agent is the reasoning hub. The date block injected into the user text is the key robustness trick — see [`docs/rationale.md`](docs/rationale.md) B.3. The system message defines tool usage, date-handling rules, and output rules (always report total count, list all when asked, split-safe).

### 2.3 Ollama — `lmChatOllama`
- **Type/version:** `@n8n/n8n-nodes-langchain.lmChatOllama` v1 ([`workflows/telegram-ollama-chatbot.json`](workflows/telegram-ollama-chatbot.json:23))
- **Config:** `model: "gemma4:e4b"` ([`workflows/telegram-ollama-chatbot.json`](workflows/telegram-ollama-chatbot.json:18)); `options.temperature: 0.7` ([`workflows/telegram-ollama-chatbot.json`](workflows/telegram-ollama-chatbot.json:19))
- **Why:** Local, private, free inference. `temperature: 0.7` balances factual accuracy (email data) with natural phrasing. Reached via `host.docker.internal:11434` (Ollama on the Mac host).

### 2.4 Simple Memory — `memoryBufferWindow`
- **Type/version:** `@n8n/n8n-nodes-langchain.memoryBufferWindow` v1.4 ([`workflows/telegram-ollama-chatbot.json`](workflows/telegram-ollama-chatbot.json:50))
- **Config:** `sessionIdType: customKey`; `sessionKey: ={{ $('Telegram Message Received').item.json.message.chat.id }}` ([`workflows/telegram-ollama-chatbot.json`](workflows/telegram-ollama-chatbot.json:45)); `contextWindowLength: 10` ([`workflows/telegram-ollama-chatbot.json`](workflows/telegram-ollama-chatbot.json:46))
- **Why:** Per-chat conversation isolation + bounded recent context. See [`docs/rationale.md`](docs/rationale.md) B.5.

### 2.5 Read OVH Emails — `toolWorkflow` (the email tool)
- **Type/version:** `@n8n/n8n-nodes-langchain.toolWorkflow` v2.2 ([`workflows/telegram-ollama-chatbot.json`](workflows/telegram-ollama-chatbot.json:102))
- **Config:** `workflowId: me7ect2HVlIIo4us` ([`workflows/telegram-ollama-chatbot.json`](workflows/telegram-ollama-chatbot.json:74)); full input schema declared ([`workflows/telegram-ollama-chatbot.json`](workflows/telegram-ollama-chatbot.json:79)); `description` tells the LLM when/how to use it ([`workflows/telegram-ollama-chatbot.json`](workflows/telegram-ollama-chatbot.json:73)).
- **Why:** Calls the standalone email sub-workflow as a tool — separation of concerns + reuse + a clear contract for the LLM. See [`docs/rationale.md`](docs/rationale.md) B.6 and [`docs/workflow-ovh-email.md`](docs/workflow-ovh-email.md).

### 2.6 Split Long Reply — `code`
- **Type/version:** `n8n-nodes-base.code` v2 ([`workflows/telegram-ollama-chatbot.json`](workflows/telegram-ollama-chatbot.json:113))
- **Config:** `MAX = 3900` ([`workflows/telegram-ollama-chatbot.json`](workflows/telegram-ollama-chatbot.json:109)); splits on `\n\n+` (blank lines) so email entries stay intact; emits `chunkIndex`/`chunkTotal`.
- **Why:** Telegram caps messages at 4096 chars; splitting on email boundaries at 3900 keeps entries whole with safety margin. See [`docs/rationale.md`](docs/rationale.md) B.7.

### 2.7 Send Reply to Telegram — `telegram` (sendMessage)
- **Type/version:** `n8n-nodes-base.telegram` v1.2 ([`workflows/telegram-ollama-chatbot.json`](workflows/telegram-ollama-chatbot.json:66))
- **Config:** `chatId: ={{ $('Telegram Message Received').item.json.message.chat.id }}` ([`workflows/telegram-ollama-chatbot.json`](workflows/telegram-ollama-chatbot.json:56)); `text: ={{ $json.output }}` ([`workflows/telegram-ollama-chatbot.json`](workflows/telegram-ollama-chatbot.json:57)); `disable_web_page_preview: true`, `appendAttribution: false`, `parse_mode: ""` ([`workflows/telegram-ollama-chatbot.json`](workflows/telegram-ollama-chatbot.json:58)).
- **Why:** Replies go to the originating chat; plain-text mode avoids Markdown/HTML parse failures on email content. See [`docs/rationale.md`](docs/rationale.md) B.8.

---

## 3. Workflow-level settings

| Setting | Value | Source | Why |
|---------|-------|--------|-----|
| `executionOrder` | `v1` | [`workflows/telegram-ollama-chatbot.json`](workflows/telegram-ollama-chatbot.json:142) | Modern, predictable node execution order. |
| `binaryMode` | `separate` | [`workflows/telegram-ollama-chatbot.json`](workflows/telegram-ollama-chatbot.json:143) | Keeps binary data separate from JSON (not heavily used here, but safe default). |
| `availableInMCP` | `true` | [`workflows/telegram-ollama-chatbot.json`](workflows/telegram-ollama-chatbot.json:144) | Exposes the assistant as an MCP tool for other clients/agents. |

---

## 4. End-to-end flow (example: "show my unread emails")

1. Telegram pushes a `message` update → **Telegram Message Received** fires.
2. **AI Assistant with Email** builds the prompt (with pre-computed Paris dates) and, recognizing an email intent, calls **Read OVH Emails** → sub-workflow `me7ect2HVlIIo4us` with `seen=false`.
3. The sub-workflow returns a formatted list + `count`.
4. The agent writes a natural-language reply.
5. **Split Long Reply** chunks it if needed (≤3900 chars).
6. **Send Reply to Telegram** posts it back to the same `chat.id`.

---

## 5. Failure modes & notes
- If Ollama is down, the agent node errors (no LLM). The workflow has no error workflow configured — for a personal bot this is acceptable, but adding one is recommended (see [`docs/rationale.md`](docs/rationale.md) E).
- `enableStreaming: false` means the user waits for the full answer; acceptable because the chunker still delivers long results in multiple messages.
- The fixed `webhookId` ([`workflows/telegram-ollama-chatbot.json`](workflows/telegram-ollama-chatbot.json:14)) ensures Telegram's registered callback URL is stable across workflow edits.
