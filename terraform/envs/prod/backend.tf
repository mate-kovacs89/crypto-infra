terraform {
  backend "s3" {
    bucket         = "crypto-bot-terraform-state-eu-north-1"
    key            = "prod/terraform.tfstate"
    region         = "eu-north-1"
    dynamodb_table = "crypto-bot-terraform-locks"
    encrypt        = true
  }
}
