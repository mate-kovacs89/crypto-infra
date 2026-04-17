#!/bin/bash
set -euo pipefail

# Setup the training EC2 instance for development/iteration.
#
# Run once after a fresh instance start, or after AMI restore to pull
# the latest code. Idempotent — safe to re-run.
#
# Prerequisites:
#   - Ubuntu 24.04 ARM64 (c7g.4xlarge)
#   - GitHub PAT in GITHUB_PAT env var (or pass as argument)
#   - Live EC2 .env accessible via SCP (for DB credentials)
#
# Usage:
#   export GITHUB_PAT=ghp_xxx
#   ./setup-training-ec2.sh
#   # or:
#   ./setup-training-ec2.sh --pull-only   # just git pull, skip installs

GITHUB_PAT="${GITHUB_PAT:-}"
PULL_ONLY=false
LIVE_HOST="${LIVE_HOST:-ubuntu@51.20.120.90}"
LIVE_SSH_KEY="${LIVE_SSH_KEY:-~/.ssh/aws.pem}"
WORK_DIR="/home/ubuntu"
GH_USER="mate-kovacs89"

if [[ "${1:-}" == "--pull-only" ]]; then
  PULL_ONLY=true
fi

log() {
  echo "[setup] $(date +%H:%M:%S) $*"
}

# ── 1. System deps ────────────────────────────────────────
if ! $PULL_ONLY; then
  log "Installing system dependencies..."
  sudo apt-get update -qq
  sudo apt-get install -y -qq libgomp1 > /dev/null

  # uv (Python package manager)
  if ! command -v uv &>/dev/null; then
    log "Installing uv..."
    curl -LsSf https://astral.sh/uv/install.sh | sh
  fi
  source "$HOME/.local/bin/env" 2>/dev/null || true

  # Node.js 22
  if ! command -v node &>/dev/null; then
    log "Installing Node.js 22..."
    curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
    sudo apt-get install -y -qq nodejs > /dev/null
  fi

  log "Versions: node=$(node --version) uv=$(uv --version) python=$(python3 --version)"
fi

source "$HOME/.local/bin/env" 2>/dev/null || true

# ── 2. Clone or pull repos ───────────────────────────────
clone_or_pull() {
  local repo=$1
  local dir="$WORK_DIR/$repo"
  if [[ -d "$dir" ]]; then
    log "Pulling $repo..."
    cd "$dir" && git pull origin main 2>&1 | tail -1
  else
    if [[ -z "$GITHUB_PAT" ]]; then
      log "ERROR: GITHUB_PAT not set, cannot clone private repos"
      exit 1
    fi
    log "Cloning $repo..."
    git clone "https://$GH_USER:$GITHUB_PAT@github.com/$GH_USER/$repo.git" "$dir" 2>&1 | tail -1
  fi
}

clone_or_pull crypto-ai-python
clone_or_pull crypto-bot-node
clone_or_pull crypto-shared

# ── 3. Submodule placement ───────────────────────────────
# Python: symlink is fine — Python import resolution doesn't walk up
# ancestor node_modules directories, so a sibling symlink works.
log "Setting up Python crypto-shared symlink..."
cd "$WORK_DIR/crypto-ai-python"
rm -rf crypto-shared 2>/dev/null || true
ln -sfn ../crypto-shared crypto-shared

# Node: copy (not symlink). Node ESM resolution follows the real path
# when walking up to find node_modules. A symlinked proto/ → crypto-shared/
# means the shared's dist imports (zod, @grpc/grpc-js) walk up from
# /home/ubuntu/crypto-shared/ts/... which is OUTSIDE the bot-node tree,
# never hitting bot-node/node_modules. This mirrors the production
# Dockerfile which does `COPY proto/ proto/` into /app/proto/.
log "Copying crypto-shared into bot-node/proto (mirrors Dockerfile layout)..."
cd "$WORK_DIR/crypto-bot-node"
rm -rf proto 2>/dev/null || true
cp -r "$WORK_DIR/crypto-shared" proto

# ── 4. Install dependencies ──────────────────────────────
if ! $PULL_ONLY; then
  log "Installing Python deps..."
  cd "$WORK_DIR/crypto-ai-python"
  uv sync --frozen 2>&1 | tail -2
  uv pip install cryptography 2>&1 | tail -1

  log "Building shared TS package inside bot-node/proto..."
  cd "$WORK_DIR/crypto-bot-node/proto/ts"
  npm ci 2>&1 | tail -1
  npm run build 2>&1 | tail -1

  # Drop build deps so runtime resolves everything (zod, @grpc/grpc-js,
  # @bufbuild/protobuf) from bot-node's own node_modules — avoids a
  # duplicated @grpc/grpc-js instance that would throw
  # "Channel credentials must be a ChannelCredentials object" at runtime.
  log "Dropping proto/ts/node_modules to force single-instance resolution..."
  rm -rf "$WORK_DIR/crypto-bot-node/proto/ts/node_modules"

  log "Installing Node.js deps..."
  cd "$WORK_DIR/crypto-bot-node"
  npm ci 2>&1 | tail -1
  npm run build 2>&1 | tail -1
else
  # Pull-only: rebuild shared TS inside the already-copied proto/ tree.
  # Re-install build deps only when missing, then drop them again.
  log "Rebuilding shared TS inside bot-node/proto..."
  cd "$WORK_DIR/crypto-bot-node/proto/ts"
  if [[ ! -d node_modules ]]; then
    npm ci 2>&1 | tail -1
  fi
  npm run build 2>&1 | tail -1
  rm -rf "$WORK_DIR/crypto-bot-node/proto/ts/node_modules"
fi

# ── 5. DB credentials (.env) ─────────────────────────────
ENV_FILE="$WORK_DIR/crypto-bot-node/.env"
if [[ ! -f "$ENV_FILE" ]]; then
  log "Copying .env from live EC2..."
  if [[ -f "$LIVE_SSH_KEY" ]]; then
    # Extract DB vars from live .env
    ssh -i "$LIVE_SSH_KEY" -o StrictHostKeyChecking=no "$LIVE_HOST" \
      "grep '^DB_' /opt/crypto-bot/.env" > "$ENV_FILE"
    cat >> "$ENV_FILE" << 'EXTRA'
INFERENCE_GRPC_URL=localhost:50051
HTTP_PORT=3000
JWT_SECRET=0000000000000000000000000000000000000000000000000000000000000000
MASTER_ENCRYPTION_KEY=0000000000000000000000000000000000000000000000000000000000000000
EXTRA
    log ".env created"
  else
    log "WARNING: SSH key not found at $LIVE_SSH_KEY — create .env manually"
  fi
else
  log ".env already exists"
fi

# ── 6. Verify ────────────────────────────────────────────
log ""
log "=== Setup complete ==="
log ""
log "Python training:"
log "  cd $WORK_DIR/crypto-ai-python"
log "  DB_URL='mysql+pymysql://...' uv run python -m training.train --symbols BTC-EUR --trials 10"
log ""
log "Walk-forward simulation:"
log "  uv run python scripts/walk_forward_simulation.py --trials 100 --db-url 'mysql+pymysql://...'"
log ""
log "Backtest (after training):"
log "  cd $WORK_DIR/crypto-bot-node"
log "  npm run backtest -- --symbols BTC-EUR --from 2025-10-01 --to 2026-03-31 --balance 1000 --decision-source grpc"
log ""
log "To create AMI snapshot (preserves this setup):"
log "  TOKEN=\$(curl -s -X PUT 'http://169.254.169.254/latest/api/token' -H 'X-aws-ec2-metadata-token-ttl-seconds: 60')"
log "  aws ec2 create-image --instance-id \$(curl -s -H \"X-aws-ec2-metadata-token: \$TOKEN\" http://169.254.169.254/latest/meta-data/instance-id) --name 'training-dev-\$(date +%Y%m%d)' --no-reboot"
