
### Day 2 (May 28, Thu)
- Created S3 bucket + DynamoDB table for remote state (later switched to S3 native locking, DynamoDB unused)
- Wrote Terraform: backend.tf, providers.tf, variables.tf, main.tf, outputs.tf
- VPC module configured: /20 CIDR (4096 IPs), 2 private /22 subnets, 2 public /24 subnets, single NAT for cost
- Migrated from deprecated dynamodb_table to use_lockfile = true
- Saved plan via `terraform plan -out=tfplan.binary` for tomorrow's apply

**Issues hit:**
- Bucket name in backend.tf was missing timestamp suffix → 404 on init
- Initial Terraform install was 32-bit; reinstalled windows_amd64

**Tomorrow (Day 3):** terraform apply tfplan.binary → creates VPC, then start EKS module
