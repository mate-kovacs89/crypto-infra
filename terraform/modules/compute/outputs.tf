output "training_instance_id" {
  value = aws_instance.training.id
}

output "training_public_ip" {
  value = aws_instance.training.public_ip
}

output "live_instance_id" {
  value = aws_instance.live.id
}

output "live_public_ip" {
  value = aws_instance.live.public_ip
}
