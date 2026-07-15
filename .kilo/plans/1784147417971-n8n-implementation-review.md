# n8n Mail Management — Implementation Review Findings

Review of the two n8n workflows (`workflows/telegram-ollama-chatbot.json`,
`workflows/ovh-email-operations.json`) against the docs in `docs/`. The code is
well-structured and follows the documented guard/validation pattern, but there
are several concrete bugs and doc-vs-code mismatches worth fixing.

## A. Real bugs (code correctness)

### A.1 — `Check Reset Command` false-positives on `/reset`/`/start` anywhere in text
- **Where:** `telegram-ollama-chatbot.json:283-302`, node `Check Reset Command`.
- **Problem:** The two conditions use `contains "/reset"` / `contains "/start"`.
  A normal message like *"please reset my password"* or *"where do I start?"*
  contains the substring and is silently intercepted as a reset command,
  skipping the LLM entirely.
- **Fix:** Match the command as a whole token. Recommended: `regex`
  `^(/reset|/start)(\s|$)` on `message.text.toLowerCase()`, or `equals` with
  trimmed text. Mirror this in `docs/workflow-telegram-chatbot.md:2.4`.

### A.2 — `Parse Input` `key=value` parser only handles ONE `=` and ONE pair
- **Where:** `ovh-email-operations.json:17`, node `Parse Input`.
- **Problem:** `d.input.split('=')` splits on the first `=`, so:
  - `subject=Hello=World` would lose `=World`.
  - Multi-pair strings (`a=1&b=2` or `a=1 b=2`) are not supported — only the
    first `key=value` is parsed, the rest is ignored.
- **Fix:** Split into pairs first (on `&` or whitespace), then each pair on the
  *first* `=`. Minor: this path is only for manual testing, so low severity, but
  it can produce silent data loss during debugging.

### A.3 — `summary` string can exceed Telegram's 4096 cap for large mailboxes
- **Where:** `ovh-email-operations.json:100`, node `Format Results`.
- **Problem:** `summary` concatenates `i: subject - from - date` for *every*
  email with NO length cap. With `limit` up to 50 (or higher if the agent
  asks for "all"), `summary` can easily exceed 4096 chars. The agent's system
  message treats `summary`/`emails` as the data source, so a huge `summary`
  inflates the agent's context and can blow the Telegram limit when echoed.
- **Fix:** Cap `summary` (e.g. join only the first N entries + `… +X more`), or
  rely on the `emails` array only and drop/truncate `summary`. Mirror the
  truncation rule in `docs/workflow-ovh-email.md:2.9` / `:5`.

## B. Doc-vs-code mismatches (documentation accuracy)

### B.1 — Model name inconsistency: `gemma4:e4b` vs `gemma4:26b-mlx`
- **README.md:117 / rationale.md:92** say `gemma4:e4b` (8B).
- **Actual code (`telegram-ollama-chatbot.json:23`)** is `gemma4:26b-mlx`.
- The chatbot doc (`workflow-telegram-chatbot.md:2.8`) correctly notes the
  26B MLX model and why. Action: update `README.md` (`Components at a glance`
  table + Quick reference) and `rationale.md` B.4 to match, OR confirm the
  intended model and align everything to it.

### B.2 — `Rationale B.12` node-id citation is wrong
- **rationale.md:153** cites `workflows/telegram-ollama-chatbot.json:338` for
  `Extract Chat Context`. The node's `jsCode` is actually at line 334; 338 is
  the node's closing brace. (Link-only; harmless but should be exact.)

### B.3 — `Rationale` line citations use `]` instead of `)`
- Many rationale.md references use `](...:NN])` (square bracket) instead of
  `](...:NN])` → actually `](...:NN])`. Several lines (e.g. 78, 109, 118,
  136, 153, 165, 181, 196, 207, 218, 224, 234) end with `]` where `)` is
  intended, producing broken markdown links. Cosmetic but worth a sweep.

## C. Design observations (not bugs, worth confirming)

### C.1 — `Reset Memory Reply` does not actually clear memory
- `workflow-telegram-chatbot.json:319` only sends a message. `Simple Memory` is
  an in-memory buffer per session, so the window naturally expires, but a
  `/reset` does NOT clear the current 10-item window — the next message still
  sees prior context until it scrolls off. Docs acknowledge this
  (`workflow-telegram-chatbot.md:2.5`, `rationale.md` E table). Confirm this is
  acceptable; if not, an explicit memory-clear step is needed.

### C.2 — No error workflow
- Both workflows lack an `errorWorkflow`/catch node. If Ollama is down or IMAP
  auth fails, the Telegram user gets no reply and the turn is silently lost.
  Docs (`workflow-telegram-chatbot.md:5`) already flag this as "recommended".
  Consider a global error workflow that posts a friendly Telegram message.

### C.3 — `markDeleted` sets `\Deleted` but never EXPUNGEs
- `ovh-email-operations.json:122` sets `\Deleted`. IMAP messages stay recoverable
  until EXPUNGE. Confirm intent (soft-delete is often desirable). If permanent
  deletion is wanted, an EXPUNGE step is required.

## D. Decided scope (user-approved)
- **Fix all 3 bugs in the workflow JSON:** A.1 (reset false-positive), A.2
  (parse), A.3 (summary cap).
- **Implement a real memory clear on `/reset`:** `Reset Memory Reply` must
  actually clear `Simple Memory` for the current `chatId`, not just send a
  message.
- (Doc fixes B.1–B.3 and behavioral C.2/C.3 are out of scope unless
  separately requested; the plan below covers only the approved code changes.)

## E. Implementation tasks (in order)
1. **A.1 — Reset command token match** (`telegram-ollama-chatbot.json`,
   `Check Reset Command`, lines 283-302): replace the two `contains`
   `/reset`/`/start` conditions with a single `regex`
   `^(/reset|/start)(\s|$)` on `{{ $json.message.text.toLowerCase() }}`
   (v2.2 `if`, `combinator` becomes irrelevant / remove second condition).
2. **A.3 — Cap `summary`** (`ovh-email-operations.json`, `Format Results`,
   lines 100): limit the concatenated summary to the first N entries
   (e.g. 15) and append `… (+X more)` when truncated; keep `emails` array
   intact (agent can still iterate it).
3. **A.2 — Robust `key=value` parse** (`ovh-email-operations.json`,
   `Parse Input`, line 17): rewrite the `input` branch to split into pairs
   (on `&` or whitespace), then each pair on the first `=`, coercing
   `true`/`false`/numbers per value.
4. **Real memory clear on reset** (`telegram-ollama-chatbot.json`): add a
   `Chat Memory Manager` node (`@n8n/n8n-nodes-langchain.memoryManager`,
   confirmed present in the running n8n version) wired to `Simple Memory` via
   an `ai_memory` connection. Configuration:
   - `mode`: `delete` (Delete Messages)
   - `deleteMode`: `all` (All Messages)
   - Connect: `Check Reset Command` (true branch) → **Chat Memory Manager** →
     `Reset Memory Reply` → `Send Reply to Telegram`.
   - The manager's `Memory` (ai_memory) input is fed by `Simple Memory`, which
     is already keyed by `$json.chatId` (`sessionKey`), so clearing the chat
     session for that `chatId` removes its buffered window.
   - Verify `Reset Memory Reply` still sends after the clear.

## F. Validation
- Import both JSON into the running n8n (`http://127.0.0.1:5678`) and run:
  - "where do I start?" → must NOT trigger reset (validates A.1).
  - "show my unread emails" with >50 recent emails → `summary` stays bounded
    (validates A.3).
  - Manual test `Parse Input` with `subject=Hello=World&a=1 b=2` → both pairs
    parsed, `=` preserved (validates A.2).
  - Send two messages, then `/reset`, then a third → third must NOT reference
    the first two (validates real clear).

## E. Validation
- Import both JSON into the running n8n (`http://127.0.0.1:5678`) and run:
  - "show my unread emails" → expect a count + list.
  - "where do I start?" → must NOT trigger reset (validates A.1).
  - "mark email 123 as read" → expect mailbox mutated (validates C.3).
  - A mailbox with >50 recent emails → `summary`/`emails` length stays bounded
    (validates A.3).
- Re-run the `key=value` and JSON parse paths in `Parse Input` for A.2.
- `grep` docs for `gemma4:e4b` and the `]`-vs-`)` link typos to confirm fixes.
