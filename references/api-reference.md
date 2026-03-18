# n8n REST API Reference

Base URL: `{n8n-host}/api/v1`
Auth: `X-N8N-API-KEY` header

## Workflows

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/workflows` | List workflows. Filter: `?active=true\|false`, `?tags=tag1,tag2` |
| GET | `/workflows/{id}` | Get full workflow definition (nodes, connections, settings) |
| POST | `/workflows` | Create workflow. Body: `{name, nodes[], connections{}, settings{}}` |
| PUT | `/workflows/{id}` | Update workflow (full body required, no partial updates) |
| DELETE | `/workflows/{id}` | Delete workflow |

### Workflow Object

```json
{
  "id": "string",
  "name": "string",
  "active": false,
  "nodes": [
    {
      "name": "Node Name",
      "type": "n8n-nodes-base.httpRequest",
      "typeVersion": 1,
      "position": [250, 300],
      "parameters": {},
      "credentials": {}
    }
  ],
  "connections": {
    "Node Name": {
      "main": [[{ "node": "Next Node", "type": "main", "index": 0 }]]
    }
  },
  "settings": {},
  "staticData": null,
  "tags": []
}
```

**Read-only fields:** `id`, `active`, `tags`, `createdAt`, `updatedAt`

## Executions

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/executions` | List executions. Filter: `?status=error\|success\|waiting`, `?workflowId=X` |
| GET | `/executions/{id}` | Get execution with full node output data and errors |
| DELETE | `/executions/{id}` | Delete execution record |

### Execution Object (detailed)

```json
{
  "id": "string",
  "finished": true,
  "mode": "webhook",
  "startedAt": "ISO8601",
  "stoppedAt": "ISO8601",
  "workflowData": { "id": "string", "name": "string" },
  "data": {
    "resultData": {
      "runData": {
        "NodeName": [{
          "startTime": 1234,
          "executionTime": 500,
          "data": { "main": [[{ "json": {} }]] },
          "error": { "message": "string", "description": "string" }
        }]
      }
    }
  }
}
```

### Error Extraction Pattern

```bash
# Extract all node errors from a failed execution
curl -s "$HOST/api/v1/executions/$ID" -H "X-N8N-API-KEY: $KEY" | \
  jq '.data.resultData.runData | to_entries[] | select(.value[0].error) | {
    node: .key,
    error: .value[0].error.message,
    description: .value[0].error.description
  }'
```

## Credentials

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/credentials` | List credentials (names/types only, no secrets) |
| GET | `/credentials/schema/{typeName}` | Get credential schema for a type |

## Pagination

- Default: 100 items per page, max: 250
- Response includes `nextCursor` when more pages exist
- Use `?cursor={value}&limit={n}` for subsequent pages

## Webhook Triggering

Workflows with Webhook nodes are triggered at:
- Production: `{host}/webhook/{path}`
- Test: `{host}/webhook-test/{path}`

No direct "execute workflow" API endpoint exists — webhooks are the standard workaround.

## Rate Limits

No documented rate limits. Community tools implement their own retry logic.
Self-hosted instances have no throttling by default.
