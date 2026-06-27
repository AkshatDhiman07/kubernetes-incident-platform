# SQS queue for alert messages
resource "aws_sqs_queue" "alerts" {
  name                       = "${var.project_name}-alerts"
  visibility_timeout_seconds = 60
  message_retention_seconds  = 345600  # 4 days
  
  tags = {
    Purpose = "Durability layer between Alertmanager and incident-service"
  }
}

# IAM policy for the SQS publisher (write-only)
resource "aws_iam_policy" "sqs_publisher" {
  name        = "${var.project_name}-sqs-publisher"
  description = "Allows sqs-publisher to send messages to alerts queue"
  
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "sqs:SendMessage",
        "sqs:GetQueueAttributes",
        "sqs:GetQueueUrl"
      ]
      Resource = aws_sqs_queue.alerts.arn
    }]
  })
}

# IAM policy for the incident-service (read + delete)
resource "aws_iam_policy" "sqs_consumer" {
  name        = "${var.project_name}-sqs-consumer"
  description = "Allows incident-service to consume from alerts queue"
  
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "sqs:ReceiveMessage",
        "sqs:DeleteMessage",
        "sqs:GetQueueAttributes",
        "sqs:GetQueueUrl"
      ]
      Resource = aws_sqs_queue.alerts.arn
    }]
  })
}

# IRSA role for sqs-publisher
resource "aws_iam_role" "sqs_publisher" {
  name = "${var.project_name}-sqs-publisher-irsa"
  
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}"
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:sub" = "system:serviceaccount:default:sqs-publisher"
          "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "sqs_publisher" {
  role       = aws_iam_role.sqs_publisher.name
  policy_arn = aws_iam_policy.sqs_publisher.arn
}

# IRSA role for incident-service (need to update existing role or create new)
resource "aws_iam_role" "incident_service" {
  name = "${var.project_name}-incident-service-irsa"
  
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}"
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:sub" = "system:serviceaccount:default:incident-service"
          "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "incident_service_sqs" {
  role       = aws_iam_role.incident_service.name
  policy_arn = aws_iam_policy.sqs_consumer.arn
}

data "aws_caller_identity" "current" {}

# Outputs
output "sqs_queue_url" {
  value = aws_sqs_queue.alerts.url
}

output "sqs_queue_arn" {
  value = aws_sqs_queue.alerts.arn
}

output "sqs_publisher_role_arn" {
  value = aws_iam_role.sqs_publisher.arn
}

output "incident_service_role_arn" {
  value = aws_iam_role.incident_service.arn
}