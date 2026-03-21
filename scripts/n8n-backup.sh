#!/usr/bin/env bash
# n8n Backup System — saves workflow snapshots to n8n + local disk
# Usage: n8n-backup.sh <command> [args...]
#
# Commands:
#   backup <workflow-id> [label]    Create backup (n8n + local)
#   rollback <workflow-id> [timestamp]  Restore from local backup
#   list <workflow-id>              List all backups for a workflow
#   cleanup <workflow-id> [keep=5]  Keep only N most recent backups in n8n

set -euo pipefail

CRED_DIR="${CRED_DIR:-$HOME/clawd/credentials}"
N8N_HOST=$(cat "$CRED_DIR/n8n-host.txt" 2>/dev/null || echo "")
N8N_API_KEY=$(cat "$CRED_DIR/n8n-api-key.txt" 2>/dev/null || echo "")
BACKUP_DIR="${BACKUP_DIR:-$HOME/clawd/backups/n8n}"

if [[ -z "$N8N_HOST" || -z "$N8N_API_KEY" ]]; then
  echo "ERROR: Missing credentials." && exit 1
fi
N8N_HOST="${N8N_HOST%/}"
API="$N8N_HOST/api/v1"

api_get() { curl -sf "$API$1" -H "X-N8N-API-KEY: $N8N_API_KEY"; }
api_post() { curl -sf -X POST "$API$1" -H "X-N8N-API-KEY: $N8N_API_KEY" -H "Content-Type: application/json" -d "$2"; }
api_put() { curl -sf -X PUT "$API$1" -H "X-N8N-API-KEY: $N8N_API_KEY" -H "Content-Type: application/json" -d "$2"; }
api_delete() { curl -sf -X DELETE "$API$1" -H "X-N8N-API-KEY: $N8N_API_KEY"; }

cmd="${1:-help}"
shift || true

case "$cmd" in
  backup)
    WF_ID="${1:-}"
    LABEL="${2:-}"
    [[ -z "$WF_ID" ]] && { echo "Usage: n8n-backup.sh backup <workflow-id> [label]"; exit 1; }

    echo "📦 Backing up workflow $WF_ID..."

    # Fetch current workflow
    WF_JSON=$(api_get "/workflows/$WF_ID")
    WF_NAME=$(echo "$WF_JSON" | jq -r '.name')
    TIMESTAMP=$(date -u +%Y-%m-%dT%H-%M-%SZ)
    SAFE_NAME=$(echo "$WF_NAME" | tr ' ' '-' | tr -cd '[:alnum:]-_')

    echo "  Workflow: $WF_NAME"

    # === 1. Save to n8n as a backup workflow ===
    BACKUP_NAME="[BACKUP] $WF_NAME - $TIMESTAMP"
    if [[ -n "$LABEL" ]]; then
      BACKUP_NAME="[BACKUP] $WF_NAME - $TIMESTAMP ($LABEL)"
    fi

    # Create backup workflow (strip id, set inactive, rename)
    BACKUP_BODY=$(echo "$WF_JSON" | jq --arg name "$BACKUP_NAME" '{
      name: $name,
      nodes: .nodes,
      connections: .connections,
      settings: .settings,
      staticData: .staticData
    }')

    BACKUP_RESULT=$(api_post "/workflows" "$BACKUP_BODY")
    BACKUP_ID=$(echo "$BACKUP_RESULT" | jq -r '.id')
    echo "  ✅ n8n backup created: $BACKUP_NAME (ID: $BACKUP_ID)"

    # === 2. Save to local disk ===
    LOCAL_DIR="$BACKUP_DIR/$WF_ID"
    mkdir -p "$LOCAL_DIR"
    LOCAL_FILE="$LOCAL_DIR/${TIMESTAMP}_${SAFE_NAME}.json"
    echo "$WF_JSON" > "$LOCAL_FILE"
    LOCAL_SIZE=$(stat -c%s "$LOCAL_FILE" 2>/dev/null || stat -f%z "$LOCAL_FILE" 2>/dev/null)
    echo "  ✅ Local backup: $LOCAL_FILE ($LOCAL_SIZE bytes)"

    # === 3. Update manifest ===
    MANIFEST="$BACKUP_DIR/manifest.json"
    if [[ ! -f "$MANIFEST" ]]; then
      echo '{"backups":[]}' > "$MANIFEST"
    fi

    ENTRY=$(jq -n \
      --arg wf_id "$WF_ID" \
      --arg wf_name "$WF_NAME" \
      --arg timestamp "$TIMESTAMP" \
      --arg trigger "${LABEL:-manual}" \
      --arg local_path "$LOCAL_FILE" \
      --arg n8n_backup_id "$BACKUP_ID" \
      --arg n8n_backup_name "$BACKUP_NAME" \
      --argjson size "${LOCAL_SIZE:-0}" \
      '{workflow_id: $wf_id, workflow_name: $wf_name, timestamp: $timestamp, trigger: $trigger, local_path: $local_path, n8n_backup_id: $n8n_backup_id, n8n_backup_name: $n8n_backup_name, size_bytes: $size}')

    jq --argjson entry "$ENTRY" '.backups += [$entry]' "$MANIFEST" > "${MANIFEST}.tmp" && mv "${MANIFEST}.tmp" "$MANIFEST"
    echo "  ✅ Manifest updated"
    echo ""
    echo "🎉 Backup complete!"
    echo "  n8n: $N8N_HOST/workflow/$BACKUP_ID"
    echo "  Local: $LOCAL_FILE"
    ;;

  rollback)
    WF_ID="${1:-}"
    TARGET_TS="${2:-}"
    [[ -z "$WF_ID" ]] && { echo "Usage: n8n-backup.sh rollback <workflow-id> [timestamp]"; exit 1; }

    LOCAL_DIR="$BACKUP_DIR/$WF_ID"
    if [[ ! -d "$LOCAL_DIR" ]]; then
      echo "ERROR: No backups found for $WF_ID" && exit 1
    fi

    if [[ -z "$TARGET_TS" ]]; then
      # Use most recent backup
      RESTORE_FILE=$(ls -t "$LOCAL_DIR"/*.json 2>/dev/null | head -1)
    else
      RESTORE_FILE=$(ls "$LOCAL_DIR"/${TARGET_TS}*.json 2>/dev/null | head -1)
    fi

    if [[ -z "$RESTORE_FILE" || ! -f "$RESTORE_FILE" ]]; then
      echo "ERROR: No backup found matching '$TARGET_TS' for $WF_ID"
      echo "Available backups:"
      ls -1 "$LOCAL_DIR"/*.json 2>/dev/null | sed 's|.*/||'
      exit 1
    fi

    echo "⚠️  Rolling back $WF_ID to: $(basename "$RESTORE_FILE")"

    # First backup the current version before rollback
    echo "  Creating pre-rollback safety backup..."
    "$0" backup "$WF_ID" "pre-rollback"

    # Restore: PUT the backed-up JSON to the workflow
    RESTORE_BODY=$(cat "$RESTORE_FILE" | jq '{name: .name, nodes: .nodes, connections: .connections, settings: .settings, staticData: .staticData}')
    api_put "/workflows/$WF_ID" "$RESTORE_BODY" > /dev/null
    echo "  ✅ Rolled back successfully!"
    echo "  Source: $(basename "$RESTORE_FILE")"
    echo "  View: $N8N_HOST/workflow/$WF_ID"
    ;;

  list)
    WF_ID="${1:-}"
    [[ -z "$WF_ID" ]] && { echo "Usage: n8n-backup.sh list <workflow-id>"; exit 1; }

    echo "📋 Backups for workflow $WF_ID"
    echo ""

    # Local backups
    LOCAL_DIR="$BACKUP_DIR/$WF_ID"
    if [[ -d "$LOCAL_DIR" ]]; then
      echo "Local backups:"
      ls -lt "$LOCAL_DIR"/*.json 2>/dev/null | awk '{print "  " $6, $7, $8, $NF}' | sed "s|$LOCAL_DIR/|  |"
    else
      echo "  (no local backups)"
    fi

    echo ""

    # n8n backups (search for [BACKUP] prefix)
    WF_NAME=$(api_get "/workflows/$WF_ID" | jq -r '.name')
    echo "n8n backups (matching '[BACKUP] $WF_NAME'):"
    api_get "/workflows" | jq -r ".data[] | select(.name | startswith(\"[BACKUP] $WF_NAME\")) | \"  \(.id) | \(.name) | \(.updatedAt)\"" 2>/dev/null || echo "  (none found)"
    ;;

  cleanup)
    WF_ID="${1:-}"
    KEEP="${2:-5}"
    [[ -z "$WF_ID" ]] && { echo "Usage: n8n-backup.sh cleanup <workflow-id> [keep=5]"; exit 1; }

    WF_NAME=$(api_get "/workflows/$WF_ID" | jq -r '.name')
    echo "🧹 Cleaning up n8n backups for '$WF_NAME' (keeping $KEEP most recent)..."

    # Get all backup workflow IDs sorted by creation date
    BACKUP_IDS=$(api_get "/workflows" | jq -r "[.data[] | select(.name | startswith(\"[BACKUP] $WF_NAME\")) | {id, name, createdAt}] | sort_by(.createdAt) | reverse | .[$KEEP:][] | .id")

    COUNT=0
    for bid in $BACKUP_IDS; do
      echo "  Deleting backup $bid..."
      api_delete "/workflows/$bid" > /dev/null 2>&1 && COUNT=$((COUNT+1))
    done

    echo "  ✅ Removed $COUNT old backups, kept $KEEP most recent"
    ;;

  help|*)
    echo "n8n Backup System"
    echo ""
    echo "Commands:"
    echo "  backup <workflow-id> [label]       Create backup (n8n + local)"
    echo "  rollback <workflow-id> [timestamp]  Restore from backup"
    echo "  list <workflow-id>                  List all backups"
    echo "  cleanup <workflow-id> [keep=5]      Remove old n8n backups"
    ;;
esac
