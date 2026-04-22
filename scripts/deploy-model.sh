#!/bin/bash
set -euo pipefail

# Deploy a PolicyBundle (model artifacts) to the live EC2 stack.
#
# Orthogonal to deploy-live.sh: this ships model files, not container
# images. The assumption is that the ai-inference image loads the bundle
# from POLICY_DIR at startup (see services/inference/src/inference/server.py),
# so we only need to (a) sync the S3 bundle to /srv/models/active/,
# (b) restart the container so it picks up the new bundle, and
# (c) keep the previous bundle around for one-command rollback.
#
# S3 layout:
#   s3://crypto-bot-models-eu-north-1/policies/v8-main/<timestamp>/
#     ├── bundle.json        main policy config (Platt)
#     ├── shadow.json        shadow policy config (Isotonic)
#     ├── seed_0.lgbm … seed_N.lgbm
#     ├── calibrator_platt.pkl
#     ├── calibrator_isotonic.pkl
#     └── meta.json
#
# Plus a plain-text pointer:
#   s3://crypto-bot-models-eu-north-1/policies/v8-main/current  (contents: <timestamp>)
#
# EC2 layout (matches compose.live.yml volume mount):
#   /srv/models/active/     mounted into the container at /app/policies/active
#   /srv/models/previous/   kept around for one-command rollback
#
# Deploy modes:
#   --version v20260422T134500Z   deploy a specific version
#   --version latest              resolve the `current` pointer first
#   --rollback                    swap /srv/models/active ↔ /srv/models/previous
#
# Usage:
#   ./scripts/deploy-model.sh --name v8-main --version latest
#   ./scripts/deploy-model.sh --name v8-main --version v20260422T134500Z
#   ./scripts/deploy-model.sh --name v8-main --rollback

LIVE_HOST="${LIVE_HOST:?Set LIVE_HOST (e.g. ubuntu@<ip>)}"
SSH_KEY="${SSH_KEY:-~/.ssh/aws.pem}"
COMPOSE_DIR="${COMPOSE_DIR:-/opt/crypto-bot}"
COMPOSE_FILE="compose.live.yml"
S3_BUCKET="${S3_BUCKET:-crypto-bot-models-eu-north-1}"
MODELS_DIR="${MODELS_DIR:-/srv/models}"
HEALTH_TIMEOUT=60

NAME=""
VERSION=""
ROLLBACK=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --name)     NAME="$2"; shift 2 ;;
    --version)  VERSION="$2"; shift 2 ;;
    --rollback) ROLLBACK=true; shift ;;
    --host)     LIVE_HOST="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

if [ -z "$NAME" ]; then
  echo "Usage: deploy-model.sh --name <policy-name> [--version <ts>|latest|--rollback]"
  exit 1
fi
if ! $ROLLBACK && [ -z "$VERSION" ]; then
  echo "Either --version <ts>|latest or --rollback is required"
  exit 1
fi

ssh_cmd() {
  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$LIVE_HOST" "$@"
}

log() {
  echo "[deploy-model] $(date +%H:%M:%S) $*"
}

health_check() {
  log "  gRPC health check (${HEALTH_TIMEOUT}s timeout)"
  local healthy=false
  for _ in $(seq 1 $HEALTH_TIMEOUT); do
    local status
    status=$(ssh_cmd "docker inspect --format='{{.State.Health.Status}}' crypto-ai-inference 2>/dev/null || echo starting")
    if [ "$status" = "healthy" ]; then healthy=true; break; fi
    sleep 1
  done
  $healthy
}

restart_inference() {
  log "  restarting ai-inference container"
  ssh_cmd "cd $COMPOSE_DIR && docker compose -f $COMPOSE_FILE up -d --force-recreate ai-inference"
}

# ── ROLLBACK PATH ──────────────────────────────────────────
if $ROLLBACK; then
  log "=== Rollback $NAME ==="
  ssh_cmd "
    set -e
    if [ ! -d '$MODELS_DIR/previous' ] || [ -z \"\$(ls -A '$MODELS_DIR/previous' 2>/dev/null)\" ]; then
      echo 'No previous bundle to roll back to' >&2
      exit 1
    fi
    sudo rsync -a --delete '$MODELS_DIR/active/' '$MODELS_DIR/_swap/'
    sudo rsync -a --delete '$MODELS_DIR/previous/' '$MODELS_DIR/active/'
    sudo rsync -a --delete '$MODELS_DIR/_swap/' '$MODELS_DIR/previous/'
    sudo rm -rf '$MODELS_DIR/_swap'
  "
  restart_inference
  if health_check; then
    log "=== Rollback complete ==="
    exit 0
  fi
  log "Rollback health-check FAILED — manual intervention required"
  exit 1
fi

# ── FORWARD DEPLOY PATH ────────────────────────────────────
if [ "$VERSION" = "latest" ]; then
  log "Resolving 'latest' via s3://$S3_BUCKET/policies/$NAME/current"
  VERSION=$(aws s3 cp "s3://$S3_BUCKET/policies/$NAME/current" - 2>/dev/null | tr -d '[:space:]' || true)
  if [ -z "$VERSION" ]; then
    echo "::error::No 'current' pointer at s3://$S3_BUCKET/policies/$NAME/current" >&2
    exit 1
  fi
  log "  → $VERSION"
fi

S3_URI="s3://$S3_BUCKET/policies/$NAME/$VERSION/"
log "=== Deploy $NAME @ $VERSION ==="
log "  source: $S3_URI"

# Sanity: bundle.json must exist in S3
if ! aws s3 ls "${S3_URI}bundle.json" > /dev/null 2>&1; then
  echo "::error::bundle.json not found at $S3_URI — version '$VERSION' does not exist" >&2
  exit 1
fi

# 1. Prepare dirs + back up current active → previous
ssh_cmd "
  set -e
  sudo mkdir -p '$MODELS_DIR/active' '$MODELS_DIR/previous' '$MODELS_DIR/staging'
  sudo chown -R ubuntu:ubuntu '$MODELS_DIR'
  if [ -n \"\$(ls -A '$MODELS_DIR/active' 2>/dev/null)\" ]; then
    rsync -a --delete '$MODELS_DIR/active/' '$MODELS_DIR/previous/'
  fi
  rm -rf '$MODELS_DIR/staging'
  mkdir -p '$MODELS_DIR/staging'
"

# 2. Download the new bundle into staging
log "  aws s3 sync → $MODELS_DIR/staging"
ssh_cmd "aws s3 sync '$S3_URI' '$MODELS_DIR/staging/' --region eu-north-1 --delete"

# 3. Validate bundle.json parses + references exist
ssh_cmd "
  set -e
  cd '$MODELS_DIR/staging'
  if [ ! -f bundle.json ]; then echo 'bundle.json missing after sync' >&2; exit 1; fi
  python3 - <<'PY'
import json, sys, pathlib
p = pathlib.Path('bundle.json')
cfg = json.loads(p.read_text())
missing = [f for f in cfg['members'] + [cfg['calibrator_path']] if not pathlib.Path(f).is_file()]
if missing:
    print('missing bundle files:', missing, file=sys.stderr)
    sys.exit(2)
print('bundle OK:', cfg['name'], 'v' + cfg['version'], len(cfg['members']), 'members')
PY
"

# 4. Promote staging → active atomically
ssh_cmd "
  set -e
  rsync -a --delete '$MODELS_DIR/staging/' '$MODELS_DIR/active/'
  rm -rf '$MODELS_DIR/staging'
"

# 5. Restart + health check
restart_inference
if ! health_check; then
  log "  UNHEALTHY — rolling back"
  ssh_cmd "
    set -e
    if [ -d '$MODELS_DIR/previous' ] && [ -n \"\$(ls -A '$MODELS_DIR/previous' 2>/dev/null)\" ]; then
      rsync -a --delete '$MODELS_DIR/previous/' '$MODELS_DIR/active/'
    fi
  "
  restart_inference
  if health_check; then
    log "Rolled back successfully (but deploy FAILED)"
  else
    log "Rollback ALSO FAILED — manual intervention required"
  fi
  exit 1
fi

# 6. Update the 'current' pointer on S3
log "  updating s3://$S3_BUCKET/policies/$NAME/current → $VERSION"
echo -n "$VERSION" | aws s3 cp - "s3://$S3_BUCKET/policies/$NAME/current" --region eu-north-1 --content-type text/plain

log "=== Deploy complete: $NAME @ $VERSION ==="
