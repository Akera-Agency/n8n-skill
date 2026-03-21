#!/usr/bin/env bash
# n8n API wrapper — handles auth and common operations
# Usage: n8n-api.sh <command> [args...]
#
# Commands:
#   workflows [--active]         List workflows
#   workflow <id>                Get workflow details
#   executions [--status error]  List executions
#   execution <id>               Get execution details
#   errors [--workflow <id>]     List failed executions with error details
#   health                       Check n8n instance connectivity

set -euo pipefail

CRED_DIR="${CRED_DIR:-$HOME/clawd/credentials}"
N8N_HOST=$(cat "$CRED_DIR/n8n-host.txt" 2>/dev/null || echo "")
N8N_API_KEY=$(cat "$CRED_DIR/n8n-api-key.txt" 2>/dev/null || echo "")

if [[ -z "$N8N_HOST" || -z "$N8N_API_KEY" ]]; then
  echo "ERROR: Missing credentials. Create:"
  echo "  $CRED_DIR/n8n-host.txt  (e.g. https://your-n8n.example.com)"
  echo "  $CRED_DIR/n8n-api-key.txt"
  exit 1
fi

# Strip trailing slash
N8N_HOST="${N8N_HOST%/}"
API="$N8N_HOST/api/v1"

api_get() {
  curl -sf "$API$1" -H "X-N8N-API-KEY: $N8N_API_KEY"
}

api_post() {
  curl -sf -X POST "$API$1" -H "X-N8N-API-KEY: $N8N_API_KEY" -H "Content-Type: application/json" -d "$2"
}

api_put() {
  curl -sf -X PUT "$API$1" -H "X-N8N-API-KEY: $N8N_API_KEY" -H "Content-Type: application/json" -d "$2"
}

api_delete() {
  curl -sf -X DELETE "$API$1" -H "X-N8N-API-KEY: $N8N_API_KEY"
}

cmd="${1:-help}"
shift || true

case "$cmd" in
  health)
    if api_get "/workflows?limit=1" > /dev/null 2>&1; then
      echo "✅ Connected to $N8N_HOST"
    else
      echo "❌ Cannot reach $N8N_HOST"
      exit 1
    fi
    ;;

  workflows)
    FILTER=""
    if [[ "${1:-}" == "--active" ]]; then FILTER="?active=true"; fi
    api_get "/workflows$FILTER" | jq '.data[] | {id, name, active, updatedAt}'
    ;;

  workflow)
    [[ -z "${1:-}" ]] && { echo "Usage: n8n-api.sh workflow <id>"; exit 1; }
    api_get "/workflows/$1" | jq '.'
    ;;

  executions)
    FILTER="?limit=20"
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --status) FILTER="$FILTER&status=$2"; shift 2 ;;
        --workflow) FILTER="$FILTER&workflowId=$2"; shift 2 ;;
        --limit) FILTER="?limit=$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    api_get "/executions$FILTER" | jq '.data[] | {id, finished, mode, workflowName: .workflowData.name, startedAt, stoppedAt}'
    ;;

  execution)
    [[ -z "${1:-}" ]] && { echo "Usage: n8n-api.sh execution <id>"; exit 1; }
    api_get "/executions/$1" | jq '.'
    ;;

  errors)
    FILTER="?status=error&limit=20"
    if [[ "${1:-}" == "--workflow" ]]; then FILTER="$FILTER&workflowId=$2"; fi
    api_get "/executions$FILTER" | jq -r '.data[] | "\(.id) | \(.workflowData.name) | \(.stoppedAt)"'
    echo ""
    echo "Run: n8n-api.sh execution <id> | jq '.data.resultData.runData | to_entries[] | select(.value[0].error)' for details"
    ;;

  create-workflow)
    [[ -z "${1:-}" ]] && { echo "Usage: n8n-api.sh create-workflow <json-file>"; exit 1; }
    api_post "/workflows" "$(cat "$1")" | jq '{id, name, active}'
    ;;

  update-workflow)
    [[ -z "${1:-}" || -z "${2:-}" ]] && { echo "Usage: n8n-api.sh update-workflow <id> <json-file>"; exit 1; }
    api_put "/workflows/$1" "$(cat "$2")" | jq '{id, name, active}'
    ;;

  delete-workflow)
    [[ -z "${1:-}" ]] && { echo "Usage: n8n-api.sh delete-workflow <id>"; exit 1; }
    api_delete "/workflows/$1"
    echo "Deleted workflow $1"
    ;;

  trigger)
    [[ -z "${1:-}" ]] && { echo "Usage: n8n-api.sh trigger <webhook-path> [json-body]"; exit 1; }
    WEBHOOK_PATH="$1"
    BODY="${2:-'{}'}"
    curl -sf -X POST "$N8N_HOST/webhook/$WEBHOOK_PATH" -H "Content-Type: application/json" -d "$BODY"
    ;;

  backup)
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    exec "$SCRIPT_DIR/n8n-backup.sh" backup "$@"
    ;;

  rollback)
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    exec "$SCRIPT_DIR/n8n-backup.sh" rollback "$@"
    ;;

  backup-list)
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    exec "$SCRIPT_DIR/n8n-backup.sh" list "$@"
    ;;

  backup-cleanup)
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    exec "$SCRIPT_DIR/n8n-backup.sh" cleanup "$@"
    ;;

  help|*)
    echo "n8n API wrapper"
    echo ""
    echo "Commands:"
    echo "  health                          Check connectivity"
    echo "  workflows [--active]            List workflows"
    echo "  workflow <id>                   Get workflow details"
    echo "  executions [--status X] [--workflow X]  List executions"
    echo "  execution <id>                  Get execution details"
    echo "  errors [--workflow <id>]        List failed executions"
    echo "  create-workflow <json>          Create from JSON file"
    echo "  update-workflow <id> <json>     Update from JSON file"
    echo "  delete-workflow <id>            Delete workflow"
    echo "  trigger <path> [json-body]      Trigger webhook"
    echo ""
    echo "Backup commands:"
    echo "  backup <id> [label]             Backup to n8n + local disk"
    echo "  rollback <id> [timestamp]       Restore from backup"
    echo "  backup-list <id>                List all backups"
    echo "  backup-cleanup <id> [keep=5]    Remove old n8n backups"
    ;;
esac
