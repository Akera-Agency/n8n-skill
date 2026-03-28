---
name: n8n
description: Manage n8n workflows, executions, and nodes via the n8n REST API and n8n-as-code CLI. Use when creating, editing, pulling, pushing, listing, debugging, or monitoring n8n workflows. Also for searching n8n nodes/templates, checking execution logs, diagnosing failed runs, triggering webhooks, or any n8n automation task. Triggers on mentions of n8n, workflow automation, n8n-as-code, n8nac, or webhook workflows.
---

# n8n Skill

Manage n8n workflows through the n8n REST API and n8n-as-code (n8nac) CLI.

## Prerequisites

- n8n instance with API access enabled
- API key stored at `~/clawd/credentials/n8n-api-key.txt`
- n8n host URL stored at `~/clawd/credentials/n8n-host.txt`
- n8nac CLI: `npx --yes n8nac <command>`

## Quick Reference

### Auth Setup

```bash
N8N_HOST=$(cat ~/clawd/credentials/n8n-host.txt)
N8N_API_KEY=$(cat ~/clawd/credentials/n8n-api-key.txt)
```

All API calls use header: `X-N8N-API-KEY: $N8N_API_KEY`

### Common Operations

| Task | Method |
|------|--------|
| List workflows | `GET /api/v1/workflows` |
| Get workflow | `GET /api/v1/workflows/{id}` |
| Create workflow | `POST /api/v1/workflows` |
| Update workflow | `PUT /api/v1/workflows/{id}` (full body required) |
| Delete workflow | `DELETE /api/v1/workflows/{id}` |
| List executions | `GET /api/v1/executions` |
| Get execution detail | `GET /api/v1/executions/{id}` |
| Delete execution | `DELETE /api/v1/executions/{id}` |

### n8nac CLI Commands

```bash
npx --yes n8nac init                    # Connect to n8n instance
npx --yes n8nac list                    # List workflows with sync status
npx --yes n8nac pull <id>               # Pull workflow to local TypeScript
npx --yes n8nac push <file>             # Push local workflow to n8n
npx --yes n8nac update-ai               # Regenerate AI context
npx --yes n8nac skills search "<query>" # Search nodes and templates
npx --yes n8nac skills node-info <node> # Full schema for a node
npx --yes n8nac skills examples search "<query>"  # Search 7,702 templates
npx --yes n8nac skills validate <file>  # Validate workflow before deploy
npx --yes n8nac convert <file> --format typescript  # JSON → TypeScript
npx --yes n8nac convert <file> --format json        # TypeScript → JSON
```

## Workflow Patterns

### List & Filter Workflows

```bash
# All workflows
curl -s "$N8N_HOST/api/v1/workflows" -H "X-N8N-API-KEY: $N8N_API_KEY" | jq '.data[] | {id, name, active}'

# Active only
curl -s "$N8N_HOST/api/v1/workflows?active=true" -H "X-N8N-API-KEY: $N8N_API_KEY" | jq '.data[] | {id, name}'
```

### Debug Failed Executions

```bash
# List failed executions
curl -s "$N8N_HOST/api/v1/executions?status=error&limit=10" \
  -H "X-N8N-API-KEY: $N8N_API_KEY" | jq '.data[] | {id, workflowId: .workflowData.name, finished, stoppedAt}'

# Get error details for a specific execution
curl -s "$N8N_HOST/api/v1/executions/{id}" \
  -H "X-N8N-API-KEY: $N8N_API_KEY" | jq '.data.resultData.runData | to_entries[] | select(.value[0].error) | {node: .key, error: .value[0].error.message}'
```

### Create a Workflow

```bash
curl -s -X POST "$N8N_HOST/api/v1/workflows" \
  -H "X-N8N-API-KEY: $N8N_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "My Workflow",
    "nodes": [...],
    "connections": {...},
    "settings": {}
  }'
```

### Trigger via Webhook

Workflows with Webhook nodes expose endpoints at:
`$N8N_HOST/webhook/<path>` (production) or `$N8N_HOST/webhook-test/<path>` (test)

```bash
curl -s -X POST "$N8N_HOST/webhook/my-path" \
  -H "Content-Type: application/json" \
  -d '{"key": "value"}'
```

## API Limitations

- `active` field is **read-only** — cannot activate/deactivate via API
- `tags` are read-only on create/update
- No PATCH — updates require full PUT with all nodes
- No direct "run workflow" endpoint — use Webhook triggers
- Pagination: max 250 per page, use `cursor` param for next page

## TypeScript Workflow Format

n8nac converts JSON workflows to TypeScript with decorators — much better for AI editing:

```typescript
import { workflow, node, links } from '@n8n-as-code/transformer';

@workflow({ id: 'abc', name: 'My Flow', active: true })
export class MyFlow {
  @node()
  Webhook = {
    type: 'n8n-nodes-base.webhook',
    parameters: { path: '/notify', method: 'POST' },
    position: [250, 300]
  };

  @node()
  Slack = {
    type: 'n8n-nodes-base.slack',
    parameters: { resource: 'message', operation: 'post', channel: '#alerts', text: '={{ $json.message }}' },
    position: [450, 300]
  };

  @links([{ from: 'Webhook', to: 'Slack' }])
  connections = {};
}
```

## Debugging Playbook

1. List failed executions → identify the workflow and node that errored
2. Read execution detail → extract error message and input data
3. Search n8nac for the failing node type → check correct parameters
4. Pull the workflow → fix the issue in TypeScript
5. Validate → push back to n8n

## Advanced: Self-Healing Pattern

For automated error recovery:
1. Poll `GET /api/v1/executions?status=error` on a schedule
2. For each failure, extract error details from execution data
3. Analyze error type (auth expired, schema mismatch, rate limit, etc.)
4. Modify workflow JSON/TS to fix the issue
5. Push the fix and re-trigger via webhook

## Backup System

Every workflow modification should be backed up first. Backups are stored in **three places**:

1. **n8n instance** — as `[BACKUP] Workflow Name - timestamp` (visible in UI)
2. **Local disk** — `~/clawd/backups/n8n/{workflow-id}/{timestamp}.json`
3. **Git** — committed to Akera-Agency/n8n-skill repo

### Backup Commands

```bash
# Backup before making changes
bash skills/n8n/scripts/n8n-backup.sh backup <workflow-id> "reason"

# Or via the API wrapper
bash skills/n8n/scripts/n8n-api.sh backup <workflow-id> "reason"

# List backups
bash skills/n8n/scripts/n8n-api.sh backup-list <workflow-id>

# Rollback to latest backup
bash skills/n8n/scripts/n8n-api.sh rollback <workflow-id>

# Rollback to specific timestamp
bash skills/n8n/scripts/n8n-api.sh rollback <workflow-id> 2026-03-21T18-17-44Z

# Cleanup old n8n backups (keep 5 most recent)
bash skills/n8n/scripts/n8n-api.sh backup-cleanup <workflow-id> 5
```

### Auto-Backup Rule

**ALWAYS backup before modifying any workflow.** The backup script saves to both n8n (visible in UI) and local disk (for fast rollback). Pre-rollback safety backups are created automatically.

## LangChain / AI Nodes

n8n has built-in LangChain nodes for AI workflows. Use these instead of raw HTTP requests to OpenRouter/OpenAI.

### OpenRouter Chat Model

```json
{
  "parameters": {
    "model": "google/gemini-2.0-flash-001",
    "options": {}
  },
  "type": "@n8n/n8n-nodes-langchain.lmChatOpenRouter",
  "typeVersion": 1,
  "name": "OpenRouter Chat Model",
  "credentials": {
    "openRouterApi": {
      "id": "CREDENTIAL_ID",
      "name": "OpenRouter account"
    }
  }
}
```

### Basic LLM Chain

Connects to an OpenRouter/OpenAI model and runs prompts.

```json
{
  "parameters": {
    "promptType": "auto",
    "batching": {}
  },
  "type": "@n8n/n8n-nodes-langchain.chainLlm",
  "typeVersion": 1.7,
  "name": "Basic LLM Chain"
}
```

**Important:** With `promptType: "auto"`, the node expects the prompt in a field called `chatInput` from the previous node.

### Connection Pattern

The OpenRouter model connects to Basic LLM Chain via `ai_languageModel`:

```json
{
  "connections": {
    "OpenRouter Chat Model": {
      "ai_languageModel": [[{
        "node": "Basic LLM Chain",
        "type": "ai_languageModel",
        "index": 0
      }]]
    },
    "Previous Node": {
      "main": [[{
        "node": "Basic LLM Chain",
        "type": "main",
        "index": 0
      }]]
    }
  }
}
```

### Passing Prompts

Set the prompt in a Code node before Basic LLM Chain:

```javascript
// Code node output - use 'chatInput' field for the prompt
return {
  chatInput: `Your prompt here with ${$json.variable}`,
  // ... other fields
};
```

The Basic LLM Chain output contains `text` field with the AI response.

### Available Models (OpenRouter)

| Model | Speed | Cost |
|-------|-------|------|
| `google/gemini-2.0-flash-001` | Fast | Low |
| `google/gemini-flash-1.5` | Fast | Very Low |
| `anthropic/claude-3-haiku` | Fast | Low |
| `anthropic/claude-3.5-sonnet` | Medium | Medium |
| `openai/gpt-4o-mini` | Fast | Low |

## Reference Files

- **API reference details**: See `references/api-reference.md` for full endpoint documentation
- **Node search patterns**: Use `npx --yes n8nac skills search` for real-time node lookups
