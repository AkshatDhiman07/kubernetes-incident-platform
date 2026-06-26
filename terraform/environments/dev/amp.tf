# Amazon Managed Service for Prometheus workspace
resource "aws_prometheus_workspace" "main" {
  alias = "${var.project_name}-amp"

  tags = {
    Purpose = "V2 metrics backend replacing self-hosted Prometheus"
  }
}

# IAM policy for the ADOT collector to write metrics to AMP
resource "aws_iam_policy" "amp_remote_write" {
  name        = "${var.project_name}-amp-remote-write"
  description = "Allows ADOT collector to remote-write metrics to AMP"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "aps:RemoteWrite",
        "aps:GetSeries",
        "aps:GetLabels",
        "aps:GetMetricMetadata"
      ]
      Resource = aws_prometheus_workspace.main.arn
    }]
  })
}

# IAM policy for incident-service to query AMP
resource "aws_iam_policy" "amp_query" {
  name        = "${var.project_name}-amp-query"
  description = "Allows incident-service to query AMP via SigV4"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "aps:QueryMetrics",
        "aps:GetSeries",
        "aps:GetLabels",
        "aps:GetMetricMetadata"
      ]
      Resource = aws_prometheus_workspace.main.arn
    }]
  })
}

# IRSA role for ADOT collector
resource "aws_iam_role" "adot_collector" {
  name = "${var.project_name}-adot-collector-irsa"

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
          "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:sub" = "system:serviceaccount:monitoring:adot-collector"
          "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "adot_collector" {
  role       = aws_iam_role.adot_collector.name
  policy_arn = aws_iam_policy.amp_remote_write.arn
}

# Attach AMP query policy to existing incident-service IRSA role
resource "aws_iam_role_policy_attachment" "incident_service_amp_query" {
  role       = aws_iam_role.incident_service.name
  policy_arn = aws_iam_policy.amp_query.arn
}

# Outputs
output "amp_workspace_id" {
  value = aws_prometheus_workspace.main.id
}

output "amp_workspace_arn" {
  value = aws_prometheus_workspace.main.arn
}

output "amp_remote_write_url" {
  value = "${aws_prometheus_workspace.main.prometheus_endpoint}api/v1/remote_write"
}

output "amp_query_url" {
  value = "${aws_prometheus_workspace.main.prometheus_endpoint}api/v1/query"
}

output "adot_collector_role_arn" {
  value = aws_iam_role.adot_collector.arn
}
