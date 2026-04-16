output "live_instance_profile_name" {
  value = aws_iam_instance_profile.live.name
}

output "training_instance_profile_name" {
  value = aws_iam_instance_profile.training.name
}
