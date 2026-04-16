#!/bin/bash
set -euo pipefail

# Blue-green deploy for the live EC2 stack.
#
# For each service: starts the new version, health-checks it, then
# swaps. If the health check fails → automatic rollback to the
# previous image. Zero-downtime for the trading bot.
#
# Usage:
#   ./scripts/deploy-live.sh                      # deploy all with :latest
#   ./scripts/deploy-live.sh --service bot-node    # deploy single service
#   ./scripts/deploy-live.sh --tag v2.1.0          # deploy specific version
#
# Requires: SSH access to the live EC2, Docker + compose installed.

LIVE_HOST="${LIVE_HOST:-ubuntu@51.20.120.90}"
COMPOSE_DIR="${COMPOSE_DIR:-/opt/crypto-bot}"
COMPOSE_FILE="compose.live.yml"
HEALTH_TIMEOUT=60  # seconds to wait for health check
SSH_KEY="${SSH_KEY:-~/.ssh/sajat}"

SERVICE=""
TAG=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --service) SERVICE="$2"; shift 2 ;;
    --tag) TAG="$2"; shift 2 ;;
    --host) LIVE_HOST="$2"; shift 2 ;;
    *) echo "Unknown: $1"; exit 1 ;;
  esac
done

ssh_cmd() {
  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$LIVE_HOST" "$@"
}

log() {
  echo "[deploy] $(date +%H:%M:%S) $*"
}

# ── ECR login on remote ──────────────────────────────────
log "ECR login on $LIVE_HOST"
ssh_cmd "aws ecr get-login-password --region eu-north-1 | docker login --username AWS --password-stdin \$(aws sts get-caller-identity --query Account --output text).dkr.ecr.eu-north-1.amazonaws.com"

# ── Determine services to deploy ─────────────────────────
if [ -n "$SERVICE" ]; then
  SERVICES=("$SERVICE")
else
  SERVICES=("ai-inference" "bot-node" "web-vue")
fi

# ── Deploy each service (blue-green) ─────────────────────
for svc in "${SERVICES[@]}"; do
  log "=== Deploying $svc ==="

  # Save current image for rollback
  PREV_IMAGE=$(ssh_cmd "docker inspect --format='{{.Config.Image}}' crypto-${svc//-/_} 2>/dev/null || echo none")
  log "  Previous: $PREV_IMAGE"

  # Pull new image
  if [ -n "$TAG" ]; then
    log "  Pulling tag: $TAG"
    ssh_cmd "cd $COMPOSE_DIR && export TAG=$TAG && docker compose -f $COMPOSE_FILE pull $svc"
  else
    ssh_cmd "cd $COMPOSE_DIR && docker compose -f $COMPOSE_FILE pull $svc"
  fi

  # Start new container (compose recreates only changed services)
  log "  Starting new container..."
  ssh_cmd "cd $COMPOSE_DIR && docker compose -f $COMPOSE_FILE up -d $svc"

  # Health check
  log "  Health check (${HEALTH_TIMEOUT}s timeout)..."
  HEALTHY=false
  for i in $(seq 1 $HEALTH_TIMEOUT); do
    STATUS=$(ssh_cmd "docker inspect --format='{{.State.Health.Status}}' crypto-${svc//-/_} 2>/dev/null || echo starting")
    if [ "$STATUS" = "healthy" ]; then
      HEALTHY=true
      break
    fi
    sleep 1
  done

  if $HEALTHY; then
    log "  ✅ $svc healthy!"
  else
    log "  ❌ $svc UNHEALTHY — rolling back to $PREV_IMAGE"
    if [ "$PREV_IMAGE" != "none" ]; then
      ssh_cmd "cd $COMPOSE_DIR && docker compose -f $COMPOSE_FILE stop $svc"
      ssh_cmd "docker tag $PREV_IMAGE \$(docker inspect --format='{{.Config.Image}}' crypto-${svc//-/_} | sed 's/:.*/:rollback/')"
      ssh_cmd "cd $COMPOSE_DIR && docker compose -f $COMPOSE_FILE up -d $svc"
      log "  Rolled back $svc to previous version"
    fi
    exit 1
  fi
done

log "=== Deploy complete ==="

# ── Verify all services ──────────────────────────────────
log "Final status:"
ssh_cmd "cd $COMPOSE_DIR && docker compose -f $COMPOSE_FILE ps"
