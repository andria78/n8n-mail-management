# Workflow: OVH Email Operations (sub-workflow / capability)

**File:** [`workflows/ovh-email-operations.json`](workflows/ovh-email-operations.json:1)
**Status:** `active: true` ([`workflows/ovh-email-operations.json`](workflows/ovh-email-operations.json:152))
**Role:** Reusable **capability** layer. Reads and mutates an OVH/Outlook mailbox over IMAP. Called by the chatbot as a `toolWorkflow` ([`workflows/telegram-ollama-chatbot.json`](workflows/telegram-ollama-chatbot.json:74)) and exposed via MCP.

This is the **child** workflow. The *why* behind each node is in [`docs/rationale.md`](docs/rationale.md) sections C.1–C.10.

---

## 1. Node map

```
Start (executeWorkflowTrigger, passthrough)
        │  main
        ▼
Parse Input (set, raw JSON)
        │  main
        ▼
Route Action (if: action === "mark")
        ├── true  ──▶ Set Email Flags (imapEnhanced, setEmailFlags)
        └── false ──▶ Read Emails (imapEnhanced, getEmailsList)
                              │  main
                              ▼
                        Format Results (code)
```

Connections: [`workflows/ovh-email-operations.json`](workflows/ovh-email-operations.json:133).

---

## 2. Node-by-node

### 2.1 Start — `executeWorkflowTrigger`
- **Type/version:** `n8n-nodes-base.executeWorkflowTrigger` v1.2 ([`workflows/ovh-email-operations.json`](workflows/ovh-email-operations.json:10))
- **Config:** `inputSource: passthrough` ([`workflows/ovh-email-operations.json`](workflows/ovh-email-operations.json:6))
- **Why:** Entry point for sub-workflow calls. `passthrough` lets the incoming tool payload flow straight into parsing without a boundary transform.

### 2.2 Parse Input — `set` (raw mode)
- **Type/version:** `n8n-nodes-base.set` v3.4 ([`workflows/ovh-email-operations.json`](workflows/ovh-email-operations.json:25))
- **Config:** `mode: raw`; `jsonOutput` expression ([`workflows/ovh-email-operations.json`](workflows/ovh-email-operations.json:17)) that merges a JSON object and, if an `input` string is present, parses either JSON or `key=value` pairs (coercing `true`/`false`/numbers); `includeOtherFields: true`; `stripBinary: true`; `attemptToConvertTypes: false` ([`workflows/ovh-email-operations.json`](workflows/ovh-email-operations.json:96)).
- **Why:** Flexible, robust input boundary. The chatbot tool passes a structured object; the workflow can also be tested directly with a raw string. Explicit coercion (not auto) keeps type control in our hands. See [`docs/rationale.md`](docs/rationale.md) C.2.

### 2.3 Route Action — `if`
- **Type/version:** `n8n-nodes-base.if` v2.2 ([`workflows/ovh-email-operations.json`](workflows/ovh-email-operations.json:55))
- **Config:** condition `action === "mark"` ([`workflows/ovh-email-operations.json`](workflows/ovh-email-operations.json:41))
- **Why:** Two distinct IMAP operations (read vs. mutate flags) with different required params. A single clear branch is easier to extend (e.g. add `delete`). See [`docs/rationale.md`](docs/rationale.md) C.3.

### 2.4 Read Emails — `imapEnhanced` (getEmailsList)
- **Type/version:** `n8n-nodes-imap-enhanced.imapEnhanced` v1 ([`workflows/ovh-email-operations.json`](workflows/ovh-email-operations.json:91))
- **Config highlights:**
  - `authentication: coreImapAccount` ([`workflows/ovh-email-operations.json`](workflows/ovh-email-operations.json:61))
  - `mailboxes: ={{ $json.mailbox || 'INBOX' }}` ([`workflows/ovh-email-operations.json`](workflows/ovh-email-operations.json:64))
  - `emailDateRange.since: ={{ $json.since || $today.minus({ days: 30 }).toFormat('yyyy-MM-dd') }}` ([`workflows/ovh-email-operations.json`](workflows/ovh-email-operations.json:66)); `before: ={{ $json.before }}` ([`workflows/ovh-email-operations.json`](workflows/ovh-email-operations.json:67))
  - `emailFlags` coercion expressions ([`workflows/ovh-email-operations.json`](workflows/ovh-email-operations.json:70]) — `''/undefined/null` → `undefined`, else boolean
  - `emailSearchFilters` (from/subject/text/to/cc/bcc) ([`workflows/ovh-email-operations.json`](workflows/ovh-email-operations.json:78))
  - `includeParts: ["textContent","flags","size"]` ([`workflows/ovh-email-operations.json`](workflows/ovh-email-operations.json:86))
  - `limit: ={{ $json.limit || 50 }}` ([`workflows/ovh-email-operations.json`](workflows/ovh-email-operations.json:87))
  - `alwaysOutputData: true` ([`workflows/ovh-email-operations.json`](workflows/ovh-email-operations.json:94])
- **Why:** The community IMAP Enhanced node provides both rich filtering and the `setEmailFlags` write operation the built-in node lacks. Defaults (30-day window, limit 50) bound cost/volume. The flag coercion is the critical correctness detail — see [`docs/rationale.md`](docs/rationale.md) C.4–C.6. `alwaysOutputData` prevents empty-result aborts (C.7).

### 2.5 Format Results — `code`
- **Type/version:** `n8n-nodes-base.code` v2 ([`workflows/ovh-email-operations.json`](workflows/ovh-email-operations.json:104)); `runOnceForAllItems`
- **Config:** maps raw IMAP envelopes → `{ uid, subject, from, date, size, flags, bodyPreview (≤300) }` plus `count` and a one-line `summary` ([`workflows/ovh-email-operations.json`](workflows/ovh-email-operations.json:100)).
- **Why:** Produces a consistent, LLM-friendly shape; surfaces `count` so the chatbot always reports totals; truncates body to control tokens. See [`docs/rationale.md`](docs/rationale.md) C.8.

### 2.6 Set Email Flags — `imapEnhanced` (setEmailFlags)
- **Type/version:** `n8n-nodes-imap-enhanced.imapEnhanced` v1 ([`workflows/ovh-email-operations.json`](workflows/ovh-email-operations.json:128))
- **Config:** `mailboxPath` RL list mode ([`workflows/ovh-email-operations.json`](workflows/ovh-email-operations.json:113)); `emailUid: ={{ $json.emailUid }}` ([`workflows/ovh-email-operations.json`](workflows/ovh-email-operations.json:118)); flags map `\Seen`/`\Flagged`/`\Deleted`/`\Answered` to `markAsRead`/`markFlagged`/`markDeleted`/`markAnswered` ([`workflows/ovh-email-operations.json`](workflows/ovh-email-operations.json:119)).
- **Why:** This is what actually mutates the mailbox ("mark as read/flagged/deleted"). Uses stable UIDs, not sequence numbers. See [`docs/rationale.md`](docs/rationale.md) C.9.

---

## 3. Workflow-level settings

| Setting | Value | Source | Why |
|---------|-------|--------|-----|
| `executionOrder` | `v1` | [`workflows/ovh-email-operations.json`](workflows/ovh-email-operations.json:154) | Predictable execution order. |
| `binaryMode` | `separate` | [`workflows/ovh-email-operations.json`](workflows/ovh-email-operations.json:155) | Safe default for JSON-centric data. |
| `availableInMCP` | `true` | [`workflows/ovh-email-operations.json`](workflows/ovh-email-operations.json:156) | Reusable by MCP clients/other agents. |
| `timeSavedMode` | `fixed` | [`workflows/ovh-email-operations.json`](workflows/ovh-email-operations.json:157) | Fixed time-saved estimate for insights. |
| `callerPolicy` | `workflowsFromSameOwner` | [`workflows/ovh-email-operations.json`](workflows/ovh-email-operations.json:158) | **Security:** only same-owner workflows may call this mailbox-mutating sub-workflow. |

---

## 4. Input contract (what callers must/should pass)

The `toolWorkflow` schema declared in the chatbot ([`workflows/telegram-ollama-chatbot.json`](workflows/telegram-ollama-chatbot.json:79)) documents these fields; `Parse Input` consumes them:

| Field | Type | Meaning |
|-------|------|---------|
| `action` | string | `"read"` (default) or `"mark"` |
| `seen` | string | filter: `true`=read only, `false`=unread only |
| `from` / `subject` / `searchText` | string | sender / subject / body-text filters |
| `flagged` / `answered` | string | flag filters (`true`/`false`) |
| `since` / `before` | string | `YYYY-MM-DD` date bounds |
| `mailbox` | string | folder (default `INBOX`) |
| `limit` | number | max results (default 50) |
| `emailUid` | string | for `mark`: UID(s), comma-separated |
| `markAsRead` / `markFlagged` / `markDeleted` | string | for `mark`: `true`/`false` |

> Note: the schema types are **strings** (the tool layer is stringly-typed), which is exactly why `Parse Input` and the `emailFlags` expressions must coerce them to real booleans/`undefined` — see [`docs/rationale.md`](docs/rationale.md) C.2 and C.6.

---

## 5. Output contract

`Format Results` returns a single item:
```json
{
  "count": 12,
  "summary": "Emails: 12 | 1: Invoice - Orange - 2026-07-10 | 2: ...",
  "emails": [
    { "uid": 123, "subject": "...", "from": "...", "date": "...", "size": 12345, "flags": "seen, flagged", "bodyPreview": "..." }
  ]
}
```
The chatbot's system message instructs the agent to **always report `count`** and to list all emails when the user asks for "all"/"the 30".

---

## 6. Notes & extension
- To add a **delete** action: add a branch in `Route Action` and a new `imapEnhanced` node using the existing `setEmailFlags` with `\Deleted` (or a dedicated delete op), reusing `emailUid`.
- To support **folders other than INBOX**: pass `mailbox` (already wired at [`workflows/ovh-email-operations.json`](workflows/ovh-email-operations.json:64) and [`workflows/ovh-email-operations.json`](workflows/ovh-email-operations.json:116)).
- `callerPolicy` ([`workflows/ovh-email-operations.json`](workflows/ovh-email-operations.json:158)) is the safety boundary for a mailbox-mutating workflow — relax only with a concrete trusted caller need.
