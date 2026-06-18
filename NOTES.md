
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

### Day 4 (May 30, Sat)
- Rebuilt VPC + EKS from scratch (t3.small Spot, cheap config)
- Cluster ACTIVE on 1.30 initially, then upgraded to 1.31 via AWS Console
- Drift created → fixed by updating eks.tf cluster_version to 1.31
- Terraform plan after re-alignment: "No changes" ✅
- Deployed first user pod (nginx-test, 10.0.4.219 on ip-10-0-4-29)
- Verified full stack: Terraform → AWS → EKS → kubelet → pod IP from VPC CIDR

**Mistake (lesson learned):**
- Clicked "Upgrade now" in console → bypassed Terraform → caused drift
- Fix: update .tf to match reality, re-plan, re-apply

**Destroyed at EOD ✓**

**Tomorrow (Day 5):** Install ArgoCD via Helm, set up gitops repo, watch ArgoCD sync the test pod

### Day 5 (May 31, Sun)
- Forgot to destroy last night → cluster running overnight (lesson reinforced)
- Installed Helm v3.16.2
- Installed ArgoCD via Helm (memory pressure on t3.small)
- Scaled cluster to 2 nodes via AWS CLI (Terraform EKS module ignores scaling_config changes)
- Disabled dex.enabled=false (was crashlooping on missing secretkey, not needed without SSO)
- Migrated GitOps manifests into main repo gitops/ folder (single-repo setup)
- nginx-demo Application running via ArgoCD, synced from gitops/apps/nginx
- Verified full GitOps loop: git push → ArgoCD detects → applies to cluster

**Issues:**
- ArgoCD dex pod crashlooping → disabled via helm upgrade --set dex.enabled=false
- EKS module ignores desired_size by default → need Day 6 fix
- Migrated from separate gitops-incident-platform repo to single-repo setup

**Destroyed at EOD ✓** (and SET THE ALARM)

**Tomorrow (Day 6):** Fix Terraform EKS scaling drift, set up Helm-based ArgoCD App for ArgoCD itself ("App of Apps" pattern), start payment-service demo app
