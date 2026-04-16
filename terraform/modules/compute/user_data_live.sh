#!/bin/bash
set -euo pipefail

# Live EC2 bootstrap (ARM64 Ubuntu 24.04)
# Installs Docker + AWS CLI + nginx reverse proxy.

apt-get update -y
apt-get install -y docker.io docker-compose-plugin awscli nginx

systemctl enable docker
systemctl start docker

usermod -aG docker ubuntu

# ECR login helper
cat > /usr/local/bin/ecr-login.sh << 'EOFSCRIPT'
#!/bin/bash
aws ecr get-login-password --region ${region} | docker login --username AWS --password-stdin $(aws sts get-caller-identity --query Account --output text).dkr.ecr.${region}.amazonaws.com
EOFSCRIPT
chmod +x /usr/local/bin/ecr-login.sh

echo "Live EC2 bootstrap complete"
