# Bi-weekly training scheduler: EventBridge triggers Lambda which
# starts the training EC2. The EC2 runs the full pipeline and shuts
# itself down when finished. Cost: ~$20/month instead of $1,180/month
# for 24/7 c7g.12xlarge.

# ── Lambda: start training EC2 ────────────────────────────

data "archive_file" "start_training" {
  type        = "zip"
  output_path = "${path.module}/lambda/start_training.zip"

  source {
    content  = <<-PYTHON
import boto3
import os

def handler(event, context):
    ec2 = boto3.client('ec2', region_name=os.environ['REGION'])
    instance_id = os.environ['TRAINING_INSTANCE_ID']

    # Check if already running (prevent double-start)
    response = ec2.describe_instances(InstanceIds=[instance_id])
    state = response['Reservations'][0]['Instances'][0]['State']['Name']

    if state == 'stopped':
        ec2.start_instances(InstanceIds=[instance_id])
        print(f"Started training instance {instance_id}")
        return {"status": "started", "instance_id": instance_id}
    else:
        print(f"Instance {instance_id} is {state}, skipping")
        return {"status": "skipped", "state": state}
PYTHON
    filename = "index.py"
  }
}

resource "aws_lambda_function" "start_training" {
  function_name    = "crypto-bot-start-training"
  role             = aws_iam_role.lambda_training.arn
  handler          = "index.handler"
  runtime          = "python3.12"
  timeout          = 30
  filename         = data.archive_file.start_training.output_path
  source_code_hash = data.archive_file.start_training.output_base64sha256

  environment {
    variables = {
      REGION               = var.region
      TRAINING_INSTANCE_ID = var.training_instance_id
    }
  }

  tags = {
    Project     = "crypto-ai"
    Environment = "prod"
  }
}

# ── IAM for Lambda ────────────────────────────────────────

resource "aws_iam_role" "lambda_training" {
  name = "crypto-bot-lambda-training-scheduler"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })

  tags = {
    Project = "crypto-ai"
  }
}

resource "aws_iam_role_policy" "lambda_ec2_start" {
  name = "ec2-start-training"
  role = aws_iam_role.lambda_training.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ec2:StartInstances",
          "ec2:DescribeInstances",
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "ec2:ResourceTag/Name" = "crypto-bot-training"
          }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:DescribeInstances",
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_logs" {
  role       = aws_iam_role.lambda_training.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# ── EventBridge: bi-weekly schedule ───────────────────────

resource "aws_cloudwatch_event_rule" "biweekly_training" {
  name                = "crypto-bot-biweekly-training"
  description         = "Start training EC2 every 2 weeks (Sunday 02:00 UTC)"
  schedule_expression = var.training_schedule

  tags = {
    Project = "crypto-ai"
  }
}

resource "aws_cloudwatch_event_target" "start_training" {
  rule = aws_cloudwatch_event_rule.biweekly_training.name
  arn  = aws_lambda_function.start_training.arn
}

resource "aws_lambda_permission" "eventbridge" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.start_training.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.biweekly_training.arn
}
