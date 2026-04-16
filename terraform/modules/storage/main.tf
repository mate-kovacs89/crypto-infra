# S3 models bucket: brownfield import.
# ECR repos: created new.

resource "aws_s3_bucket" "models" {
  bucket = var.models_bucket_name

  tags = {
    Name        = "crypto-bot-models"
    Project     = "crypto-ai"
    Environment = "prod"
  }
}

resource "aws_s3_bucket_versioning" "models" {
  bucket = aws_s3_bucket.models.id
  versioning_configuration {
    status = "Enabled"
  }
}

# ── ECR Repositories (NEW) ───────────────────────────────

resource "aws_ecr_repository" "bot_node" {
  name                 = "crypto-bot-node"
  image_tag_mutability = "MUTABLE"
  force_delete         = false

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Project     = "crypto-ai"
    Environment = "prod"
  }
}

resource "aws_ecr_repository" "ai_python" {
  name                 = "crypto-ai-python"
  image_tag_mutability = "MUTABLE"
  force_delete         = false

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Project     = "crypto-ai"
    Environment = "prod"
  }
}

resource "aws_ecr_repository" "web_vue" {
  name                 = "crypto-web-vue"
  image_tag_mutability = "MUTABLE"
  force_delete         = false

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Project     = "crypto-ai"
    Environment = "prod"
  }
}

# Lifecycle policy: keep last 10 images, expire untagged after 7 days.
resource "aws_ecr_lifecycle_policy" "cleanup" {
  for_each   = toset(["crypto-bot-node", "crypto-ai-python", "crypto-web-vue"])
  repository = each.key

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after 7 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 7
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep last 10 tagged images"
        selection = {
          tagStatus   = "tagged"
          tagPrefixList = ["v"]
          countType   = "imageCountMoreThan"
          countNumber = 10
        }
        action = { type = "expire" }
      }
    ]
  })

  depends_on = [
    aws_ecr_repository.bot_node,
    aws_ecr_repository.ai_python,
    aws_ecr_repository.web_vue,
  ]
}
