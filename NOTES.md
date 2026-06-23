
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

### Day 6 (Jun 1, Mon) — biggest session yet
**Rebuilt with bigger nodes:**
- Upgraded eks.tf to t3.medium (17 pods/node vs t3.small's 11)
- Added update_config to allow Terraform to update node group scaling
- Fresh apply: VPC + EKS in ~15 min

**Phase 1 — Observability bootstrap:**
- ArgoCD reinstalled, 4 Apps re-bootstrapped from git
- kube-prometheus-stack via Helm with sized resource limits
- All node-exporters running this time (no pod limit wall)
- Verified app metrics with payment-service v0.2.0 (prometheus-fastapi-instrumentator)
- Wrote 6 alert rules across payment + order services
- Discovered `up == 0` doesn't fire when target absent → use `absent()`

**Phase 2 — Logs:**
- Installed Loki SingleBinary mode via Helm
- Hit EBS CSI driver missing — installed it with IRSA setup
- Promtail DaemonSet shipping logs to Loki
- Grafana datasource configured, LogQL queries working

**Phase 3 — Failure injection:**
- payment-service v0.3.0 with FAILURE_MODE env var
- Modes: none, slow, errors, crash_loop
- Tested errors mode → PaymentServiceHighErrorRate fired as expected

**Issues hit (all resolved):**
- EKS module ignored desired_size again (still on radar to fix properly)
- Loki PVC stuck Pending → missing EBS CSI driver (gotcha)
- ArgoCD selfHeal reverted kubectl scale → had to test failures via git
- Git Bash file:// path mismatch with aws CLI → cygpath fix

**Destroyed at EOD ✓**

**Status: ~80% of infrastructure done. Next: incident response service (the AI piece).**

### Day 6 extended (Jun 22) — second session
**Built tonight:**
- incident-service v0.1.0 (FastAPI + Prometheus instrumentation)
- /webhook/alert endpoint receives Alertmanager payloads
- ECR repo: incident-service
- K8s manifests + ServiceMonitor

**Wired:**
- Custom Alertmanager config via secret in monitoring namespace
- Routes all alerts (except Watchdog/InfoInhibitor null route) to incident-service
- Verified: real alert (PaymentServiceHighErrorRate) propagated through full chain

**Issues hit:**
- OIDC changes on cluster recreate broke EBS CSI IAM trust policy
- ArgoCD apps stuck OutOfSync/Missing because CRDs not installed yet (chicken-egg)
- Worked around by kubectl apply directly (lost some GitOps purity, acknowledge debt)

**Status:** End-to-end loop proven. Foundation for AI work tomorrow.

**Destroyed at EOD ✓ (very late)**
