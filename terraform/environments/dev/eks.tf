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

  # Managed node group — t3.medium Spot for higher pod limit (17/node) and 4GB RAM
  eks_managed_node_groups = {
    main = {
      name = "main-nodes"

      instance_types = ["t3.medium", "t3a.medium"]
      capacity_type  = "SPOT"

      min_size     = 2
      max_size     = 4
      desired_size = 2

      ami_type = "AL2023_x86_64_STANDARD"

      update_config = {
        max_unavailable_percentage = 33
      }
    }
  }

  enable_cluster_creator_admin_permissions = true

  tags = {
    Component = "eks"
  }
}