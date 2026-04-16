# IAM roles + instance profiles for EC2 instances.
# Each EC2 gets a role with the minimum permissions it needs.

# ── Shared assume-role policy (EC2 can assume) ────────────

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

# ── Live EC2 role ─────────────────────────────────────────
# Needs: ECR pull, S3 model read, SSM read (secrets)

resource "aws_iam_role" "live" {
  name               = "crypto-bot-live-ec2-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json

  tags = {
    Project = "crypto-ai"
    Role    = "live"
  }
}

resource "aws_iam_role_policy" "live_ecr" {
  name = "ecr-pull"
  role = aws_iam_role.live.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetAuthorizationToken",
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy" "live_s3_models" {
  name = "s3-models-read"
  role = aws_iam_role.live.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:ListBucket",
        ]
        Resource = [
          var.models_bucket_arn,
          "${var.models_bucket_arn}/*",
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy" "live_ssm" {
  name = "ssm-read-secrets"
  role = aws_iam_role.live.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters",
          "ssm:GetParametersByPath",
        ]
        Resource = "arn:aws:ssm:${var.region}:*:parameter/crypto-bot/*"
      }
    ]
  })
}

resource "aws_iam_instance_profile" "live" {
  name = "crypto-bot-live-ec2-profile"
  role = aws_iam_role.live.name
}

# ── Training EC2 role ─────────────────────────────────────
# Needs: ECR pull, S3 model read+write, SSM read, EC2 self-stop

resource "aws_iam_role" "training" {
  name               = "crypto-bot-training-ec2-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json

  tags = {
    Project = "crypto-ai"
    Role    = "training"
  }
}

resource "aws_iam_role_policy" "training_ecr" {
  name = "ecr-pull"
  role = aws_iam_role.training.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetAuthorizationToken",
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy" "training_s3_models" {
  name = "s3-models-readwrite"
  role = aws_iam_role.training.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:ListBucket",
          "s3:DeleteObject",
        ]
        Resource = [
          var.models_bucket_arn,
          "${var.models_bucket_arn}/*",
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy" "training_ssm" {
  name = "ssm-read-secrets"
  role = aws_iam_role.training.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters",
          "ssm:GetParametersByPath",
        ]
        Resource = "arn:aws:ssm:${var.region}:*:parameter/crypto-bot/*"
      }
    ]
  })
}

resource "aws_iam_role_policy" "training_self_stop" {
  name = "ec2-self-stop"
  role = aws_iam_role.training.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ec2:StopInstances"]
        Resource = "*"
        Condition = {
          StringEquals = {
            "ec2:ResourceTag/Role" = "training"
          }
        }
      }
    ]
  })
}

resource "aws_iam_instance_profile" "training" {
  name = "crypto-bot-training-ec2-profile"
  role = aws_iam_role.training.name
}
