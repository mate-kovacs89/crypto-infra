#!/bin/bash
set -euo pipefail

# Training EC2 bootstrap (ARM64 Ubuntu 24.04)
# TWO modes:
#   1. First boot: install Docker + tools
#   2. Every subsequent start: run training pipeline + self-stop

MARKER="/opt/crypto-bot/.bootstrapped"
LOG="/var/log/crypto-training.log"

# ── First-boot setup ─────────────────────────────────────
if [ ! -f "$MARKER" ]; then
    echo "$(date) First boot — installing dependencies" | tee -a $LOG

    apt-get update -y
    apt-get install -y docker.io docker-compose-plugin awscli jq

    systemctl enable docker
    systemctl start docker
    usermod -aG docker ubuntu

    mkdir -p /opt/crypto-bot
    touch "$MARKER"

    echo "$(date) First boot complete" | tee -a $LOG
fi

# ── Training pipeline (runs EVERY start) ──────────────────
# The EventBridge scheduler starts this EC2 every 2 weeks.
# After training completes, the machine shuts itself down.

echo "$(date) Training pipeline starting" | tee -a $LOG

# ECR login
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
aws ecr get-login-password --region ${region} | \
    docker login --username AWS --password-stdin $${ACCOUNT_ID}.dkr.ecr.${region}.amazonaws.com

# Pull latest training image
docker pull $${ACCOUNT_ID}.dkr.ecr.${region}.amazonaws.com/crypto-ai-python:latest || true

# Run training container
# The container runs:
#   1. train.py --trials 300 --ensemble-seeds 42,43,44,45,46 --holdout-days 30
#   2. post_retrain.py (calibration + threshold sweep + champion-challenger)
#   3. If new champion → push model to S3
docker run --rm \
    --name crypto-training \
    -e TRAINING_DB_URL="$${TRAINING_DB_URL}" \
    -e TRAINING_SYMBOLS="$${TRAINING_SYMBOLS}" \
    -e TRAINING_OPTUNA_TRIALS=300 \
    -e TRAINING_HOLDOUT_DAYS=30 \
    -e AWS_DEFAULT_REGION=${region} \
    -v /opt/crypto-bot/models:/app/models \
    $${ACCOUNT_ID}.dkr.ecr.${region}.amazonaws.com/crypto-ai-python:latest \
    python -m training.train \
        --ensemble-seeds 42,43,44,45,46 \
    2>&1 | tee -a $LOG

echo "$(date) Training complete — shutting down" | tee -a $LOG

# Self-stop: the instance goes to 'stopped' state.
# Next bi-weekly trigger will start it again.
shutdown -h now
