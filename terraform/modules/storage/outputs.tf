output "models_bucket_arn" {
  value = aws_s3_bucket.models.arn
}

output "ecr_bot_node_url" {
  value = aws_ecr_repository.bot_node.repository_url
}

output "ecr_ai_python_url" {
  value = aws_ecr_repository.ai_python.repository_url
}

output "ecr_web_vue_url" {
  value = aws_ecr_repository.web_vue.repository_url
}
