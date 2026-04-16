variable "training_instance_id" {
  type        = string
  description = "EC2 instance ID of the training machine"
}

variable "region" {
  type    = string
  default = "eu-north-1"
}

variable "training_schedule" {
  type        = string
  description = "EventBridge cron expression for training frequency"
  # Every other Sunday at 02:00 UTC (bi-weekly)
  # Note: EventBridge doesn't support "every 2 weeks" natively.
  # Use "every Sunday" and add a Lambda check for odd/even week,
  # OR use "rate(14 days)" which starts from rule creation time.
  default = "rate(14 days)"
}
