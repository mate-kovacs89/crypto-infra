output "training_sg_id" {
  value = aws_security_group.training.id
}

output "live_sg_id" {
  value = aws_security_group.live.id
}

output "rds_sg_id" {
  value = aws_security_group.rds.id
}
