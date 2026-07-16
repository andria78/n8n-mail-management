# n8n access & workflow sync

How to reach the n8n instance, the two MCP/API credential models, and the
correct way to push workflow JSON changes back to the instance.

## 1. How to reach n8n

| What | Value |
|------|-------|
| Public URL (Cloudflare Tunnel) | `https://n8n.andrianarison.com` |
| Local n8n (docker, localhost only) | `http://127.0.0.1:5678` |
| Chatbot workflow ID | `E6zR3WkUfXjCdeE6` |
| Email sub-workflow ID | `me7ect2HVlIIo4us` |
| n8n version | 2.29.10 |

The container is in `docker-compose.yml` and only binds `127.0.0.1:5678`; the
public host is exposed through a Cloudflare Tunnel. There is no open inbound
port.

## 2. Two separate credentials (do not confuse them)

| Credential | Audience (`aud`) | Used for | Header |
|-----------|-----------------|----------|--------|
| MCP Bearer JWT | `mcp-server-api` | The instance-level MCP server at `/mcp-server/http` (Kilo's `n8n-mcp` tool) | `Authorization: Bearer <jwt>` |
| REST API key | `public-api` | The n8n REST API at `/api/v1/*` (curl / scripts) | `X-N8N-API-KEY: <key>` |

The MCP JWT is **rejected** by `/api/v1` and the REST key is **rejected** by
the MCP endpoint. They are not interchangeable.

### 2.1 MCP config (Kilo)

`kilo.json` must use the **remote** MCP server (the local `npx n8n-mcp` package
does not work here — it misroutes to the UI and returns HTML):

```json
"mcp": {
  "n8n-mcp": {
    "type": "remote",
    "url": "https://n8n.andrianarison.com/mcp-server/http",
    "headers": {
      "Authorization": "Bearer <mcp-jwt>"
    }
  }
}
```

After editing `kilo.json`, **reload the MCP config** (restart the Kilo session /
reconnect MCP) so the instance-level tools (`search_workflows`,
`get_workflow_details`, `update_workflow`, `publish_workflow`, …) load.

### 2.2 REST API key

Create it in the n8n UI: **Settings → API → Create API key**. It is shown once.
Keep it out of git (`.gitignore` already covers secrets; add `*.key` / `.env`).

Verify:

```bash
curl -s -H "X-N8N-API-KEY: <key>" \
  https://n8n.andrianarison.com/api/v1/workflows
```

## 3. Comparing local files vs the live instance

Use the MCP `get_workflow_details` tool (or `GET /api/v1/workflows/:id`) and
diff node names, parameters, and connections against `workflows/*.json`.

Note: the MCP/`get_workflow_details` response **strips credential references**,
and so does the REST export. Comparisons should therefore ignore credentials
and focus on nodes / parameters / connections.

## 4. Pushing workflow JSON — the correct way

### 4.1 Why `PUT /api/v1/workflows/:id` does NOT work for active workflows

A `PUT` on an **active** workflow triggers a publish/re-validation step that
requires the credential references to be embedded in each node. However, n8n's
`GET` response **does not include credential IDs** anywhere in the JSON. Any
payload you build from the export therefore fails with:

```
Cannot publish workflow: N nodes have configuration issues:
  Node "Telegram Message Received": Missing required credential: telegramApi
  Node "Ollama": Missing required credential: ollamaApi
  Node "Send Reply to Telegram": Missing required credential: telegramApi
```

You also cannot simply re-`PUT` the exported JSON after stripping read-only
fields — the same credential validation blocks it. This is an n8n REST API
limitation, not a misconfiguration.

### 4.2 Recommended: MCP `update_workflow` (preserves credentials)

The instance-level MCP server edits the workflow **draft** with operation
objects and keeps credential bindings intact. Use it for node-only / parameter
changes:

1. Reload Kilo MCP so the remote tools are active.
2. Call `update_workflow` with a diff operation targeting only the changed node
   (e.g. set `Read OVH Emails` → `workflowInputs.value` = `{"limit": 0}`).
3. Call `publish_workflow` (workflow ID) to activate the new draft.

This is the path used for the `limit: 0` sync on `Telegram Ollama Chatbot`
(node `Read OVH Emails`).

### 4.3 Alternative: UI import (zero risk for structural changes)

Workflows → Import from JSON. n8n's importer resolves credentials by type/name,
so it works where the REST `PUT` fails. Prefer this for adding/removing nodes.

### 4.4 REST `POST` (create new workflow only)

`POST /api/v1/workflows` with a clean body (`name`, `nodes`, `connections`,
`settings: {executionOrder:"v1"}`) works for **new** workflows. Do not use it to
update an existing active workflow.

## 5. Two-way sync that preserves credentials (Source Control)

The MCP/REST export **strips credential references** (§3), so committing an
exported workflow JSON loses the credential link and the node shows "Missing
required credential" after re-import. The only reliable two-way sync that keeps
credentials linked is n8n's built-in **Source Control** (git), because it commits
workflows with credentials referenced by **name** (not the instance-specific
numeric ID) and re-links them by name on pull.

### 5.1 One-time setup (in the n8n UI)

1. **Settings → Source Control → Connect**.
2. Choose **Git** and point it at this repo:
   `https://github.com/andria78/n8n-mail-management`
   (branch `main`, workflows directory `workflows/`).
3. Enable **Include credentials in commit**. n8n then writes the
   `credentials` block into each node using the credential **name** as the
   reference, which survives re-import on any instance that has a credential
   with that name.
4. Click **Push** to commit the current live workflows (with credential names)
   to the repo. This is the authoritative backup + analysis source.

### 5.2 Daily two-way workflow

- **Edit in n8n UI → push to git:** make changes in n8n, then Source Control →
  **Push**. The repo JSON updates with the same credential-name links. Safe for
  analysis, diffing, and backup.
- **Edit JSON in repo → pull into n8n:** edit `workflows/*.json`, commit, then
  Source Control → **Pull** in n8n. Credentials re-link by name automatically
  (as long as a credential with that name exists on the instance).

### 5.3 Why this fixes the lost-link problem

- Exported JSON references credentials by numeric `id` (instance-specific) and
  n8n even strips it on `GET` — so re-import drops the link.
- Source Control uses the credential **name**, which is stable across instances.
  As long as the destination instance has a credential with the same name, the
  link is restored on pull.

## 6. REST API backup script (analysis only — no credential linking)

`scripts/pull-workflows.sh` downloads live workflows via `GET /api/v1/workflows/:id`
using the REST API key (§2.2). Use it for **backup/analysis/diff**, NOT for
restoring credential links (exports strip them — §3). Keep the key in `.env`
(already git-ignored) or pass via env var `N8N_API_KEY`.

```bash
N8N_API_KEY=<key> ./scripts/pull-workflows.sh
```

## 7. Current sync status

As of the last check, the two local files already match the live instance
(`limit: 0` present on `Read OVH Emails`; same nodes/connections). No push was
required. Once Source Control is connected (§5.1) the repo becomes the
authoritative, credential-name-linked backup.
