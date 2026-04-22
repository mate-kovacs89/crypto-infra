#!/bin/bash
set -euo pipefail

# Blue-green deploy for the live EC2 stack.
#
# Deploys a specific release tag (semver). Updates the tag env var
# on the remote, pulls the image, recreates the service, and health-
# checks it. On failure, rolls back to the previous tag.
#
# Usage:
#   ./scripts/deploy-live.sh --service bot-node --tag v1.2.0
#   ./scripts/deploy-live.sh --service all --tag v1.2.0
#
# Requires: SSH access to the live EC2, Docker + compose on remote.

LIVE_HOST="${LIVE_HOST:?Set LIVE_HOST (e.g. ubuntu@<ip>)}"
COMPOSE_DIR="${COMPOSE_DIR:-/opt/crypto-bot}"
COMPOSE_FILE="compose.live.yml"
HEALTH_TIMEOUT=60
SSH_KEY="${SSH_KEY:-~/.ssh/aws.pem}"

SERVICE=""
TAG=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --service) SERVICE="$2"; shift 2 ;;
    --tag)     TAG="$2"; shift 2 ;;
    --host)    LIVE_HOST="$2"; shift 2 ;;
    *) echo "Unknown: $1"; exit 1 ;;
  esac
done

if [ -z "$SERVICE" ] || [ -z "$TAG" ]; then
  echo "Usage: deploy-live.sh --service <bot-node|ai-inference|web-vue|all> --tag <vX.Y.Z>"
  exit 1
fi

ssh_cmd() {
  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$LIVE_HOST" "$@"
}

scp_cmd() {
  scp -i "$SSH_KEY" -o StrictHostKeyChecking=no "$@"
}

log() {
  echo "[deploy] $(date +%H:%M:%S) $*"
}

# Sync the authoritative compose.live.yml from this repo to the live
# EC2 before every deploy. Without this, changes to volumes / env vars /
# service definitions in the repo would never reach production — the
# image swap alone does not re-apply compose-level configuration. The
# repo is the single source of truth; the host copy in $COMPOSE_DIR is
# a disposable cache.
sync_compose_file() {
  local src_compose
  src_compose="$(dirname "$0")/../docker/$COMPOSE_FILE"
  if [ ! -f "$src_compose" ]; then
    log "  WARNING: $src_compose not found in repo — skipping compose sync"
    return 0
  fi
  log "  Syncing $COMPOSE_FILE: repo → $LIVE_HOST:$COMPOSE_DIR/"
  scp_cmd "$src_compose" "$LIVE_HOST:$COMPOSE_DIR/$COMPOSE_FILE"
}

# Map service name → env var in .env, compose service name, container name
service_env_var() {
  case $1 in
    bot-node)     echo "BOT_NODE_TAG" ;;
    ai-inference) echo "AI_PYTHON_TAG" ;;
    web-vue)      echo "WEB_VUE_TAG" ;;
  esac
}

service_container() {
  case $1 in
    bot-node)     echo "crypto-bot-node" ;;
    ai-inference) echo "crypto-ai-inference" ;;
    web-vue)      echo "crypto-web-vue" ;;
  esac
}

# Read current tag from remote .env
read_current_tag() {
  local env_var
  env_var=$(service_env_var "$1")
  ssh_cmd "grep -oP '${env_var}=\K.*' $COMPOSE_DIR/.env 2>/dev/null || echo 'latest'"
}

# Update tag in remote .env (upsert)
set_remote_tag() {
  local env_var tag
  env_var=$(service_env_var "$1")
  tag="$2"
  ssh_cmd "
    if grep -q '^${env_var}=' $COMPOSE_DIR/.env 2>/dev/null; then
      sed -i 's|^${env_var}=.*|${env_var}=${tag}|' $COMPOSE_DIR/.env
    else
      echo '${env_var}=${tag}' >> $COMPOSE_DIR/.env
    fi
  "
}

# Deploy a single service with health check + rollback
deploy_service() {
  local svc="$1"
  local tag="$2"
  local container
  container=$(service_container "$svc")

  log "=== Deploying $svc → $tag ==="

  # 1. Save current tag for rollback
  local prev_tag
  prev_tag=$(read_current_tag "$svc")
  log "  Previous tag: $prev_tag"

  # 2. Update tag in .env
  set_remote_tag "$svc" "$tag"
  log "  Updated .env: $(service_env_var "$svc")=$tag"

  # 2.5. Sync compose file from repo (single source of truth)
  sync_compose_file

  # 3. Pull new image
  log "  Pulling image..."
  ssh_cmd "cd $COMPOSE_DIR && docker compose -f $COMPOSE_FILE pull $svc"

  # 4. Recreate service
  log "  Recreating container..."
  ssh_cmd "cd $COMPOSE_DIR && docker compose -f $COMPOSE_FILE up -d --force-recreate $svc"

  # 5. Health check
  log "  Health check (${HEALTH_TIMEOUT}s timeout)..."
  local healthy=false
  for _ in $(seq 1 $HEALTH_TIMEOUT); do
    local status
    status=$(ssh_cmd "docker inspect --format='{{.State.Health.Status}}' $container 2>/dev/null || echo starting")
    if [ "$status" = "healthy" ]; then
      healthy=true
      break
    fi
    sleep 1
  done

  if $healthy; then
    log "  $svc $tag — healthy"
  else
    log "  $svc $tag — UNHEALTHY, rolling back to $prev_tag"
    set_remote_tag "$svc" "$prev_tag"
    ssh_cmd "cd $COMPOSE_DIR && docker compose -f $COMPOSE_FILE pull $svc && docker compose -f $COMPOSE_FILE up -d --force-recreate $svc"
    log "  Rolled back $svc to $prev_tag"
    exit 1
  fi
}

# ── ECR login on remote ──────────────────────────────────
log "ECR login on $LIVE_HOST"
ssh_cmd "aws ecr get-login-password --region eu-north-1 | docker login --username AWS --password-stdin \$(aws sts get-caller-identity --query Account --output text).dkr.ecr.eu-north-1.amazonaws.com"

# ── Deploy ────────────────────────────────────────────────
if [ "$SERVICE" = "all" ]; then
  # Order matters: inference first (bot depends on it), then bot, then web
  deploy_service "ai-inference" "$TAG"
  deploy_service "bot-node" "$TAG"
  deploy_service "web-vue" "$TAG"
else
  deploy_service "$SERVICE" "$TAG"
fi

log "=== Deploy complete ==="
ssh_cmd "cd $COMPOSE_DIR && docker compose -f $COMPOSE_FILE ps --format 'table {{.Name}}\t{{.Image}}\t{{.Status}}'"
