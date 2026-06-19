module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = "${local.name_prefix}-cluster"
  cluster_version = "1.31"

  # Use the VPC and subnets we created
  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # Make the API endpoint publicly accessible (for kubectl from your laptop)
  cluster_endpoint_public_access = true

  # Enable IRSA (IAM Roles for Service Accounts) — needed for pods to assume AWS roles
  enable_irsa = true

  # Control plane logs to CloudWatch (gives you audit + API server logs)
  cluster_enabled_log_types = ["api", "audit", "authenticator"]

  # Managed node group — Spot for cost
  eks_managed_node_groups = {
    spot = {
      name = "spot-nodes"

      instance_types = ["t3.small", "t3a.small"]
      capacity_type  = "SPOT"

      min_size     = 1
      max_size     = 2
      desired_size = 2

      # Use AL2023 (Amazon Linux 2023) — newer default
      ami_type = "AL2023_x86_64_STANDARD"
    }
  }

  enable_cluster_creator_admin_permissions = true

  tags = {
    Component = "eks"
  }
}
