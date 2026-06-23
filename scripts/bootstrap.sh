#!/usr/bin/env bash
# Bootstrap script for incident platform
# Run AFTER `terraform apply` completes and 2 nodes are Ready
# Usage: bash scripts/bootstrap.sh
set -euo pipefail

CLUSTER_NAME="incident-platform-dev-cluster"
REGION="us-east-1"
ACCOUNT_ID="136492549275"

log() { echo "[$(date +%H:%M:%S)] $*"; }

log "1/8 Wiring kubectl"
aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER_NAME"
kubectl get nodes

log "2/8 Updating EBS CSI driver IAM trust policy for current OIDC"
NEW_OIDC=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" \
  --query 'cluster.identity.oidc.issuer' --output text | sed 's|https://||')
log "  OIDC: $NEW_OIDC"

cat > ~/csi-trust-policy.json <<TRUST
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${NEW_OIDC}" },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": { "StringEquals": {
      "${NEW_OIDC}:sub": "system:serviceaccount:kube-system:ebs-csi-controller-sa",
      "${NEW_OIDC}:aud": "sts.amazonaws.com"
    }}
  }]
}
TRUST

WIN_PATH=$(cygpath -w ~/csi-trust-policy.json 2>/dev/null || echo ~/csi-trust-policy.json)
aws iam update-assume-role-policy \
  --role-name AmazonEKS_EBS_CSI_DriverRole \
  --policy-document "file://$WIN_PATH" || {
    log "  Trust policy update failed; creating role..."
    aws iam create-role --role-name AmazonEKS_EBS_CSI_DriverRole \
      --assume-role-policy-document "file://$WIN_PATH"
    aws iam attach-role-policy --role-name AmazonEKS_EBS_CSI_DriverRole \
      --policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy
  }

# OIDC provider may need creation
if ! aws iam list-open-id-connect-providers | grep -q "$NEW_OIDC"; then
  log "  Creating OIDC provider in IAM"
  THUMBPRINT=$(echo | openssl s_client -servername oidc.eks.us-east-1.amazonaws.com \
    -connect oidc.eks.us-east-1.amazonaws.com:443 2>/dev/null | \
    openssl x509 -fingerprint -noout | sed 's/://g' | awk -F= '{print tolower($2)}')
  aws iam create-open-id-connect-provider --url "https://$NEW_OIDC" \
    --thumbprint-list "$THUMBPRINT" --client-id-list sts.amazonaws.com
fi

log "3/8 Installing EBS CSI driver addon"
aws eks create-addon --cluster-name "$CLUSTER_NAME" --region "$REGION" \
  --addon-name aws-ebs-csi-driver \
  --service-account-role-arn "arn:aws:iam::${ACCOUNT_ID}:role/AmazonEKS_EBS_CSI_DriverRole" || \
  log "  Addon may already exist; continuing"

log "  Waiting for CSI driver to be ACTIVE..."
for i in {1..30}; do
  STATUS=$(aws eks describe-addon --cluster-name "$CLUSTER_NAME" --region "$REGION" \
    --addon-name aws-ebs-csi-driver --query 'addon.status' --output text 2>/dev/null || echo "MISSING")
  if [ "$STATUS" = "ACTIVE" ]; then break; fi
  sleep 10
done
log "  CSI driver: $STATUS"

kubectl patch storageclass gp2 -p \
  '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

log "4/8 Installing kube-prometheus-stack (creates ServiceMonitor + PrometheusRule CRDs)"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm repo add grafana https://grafana.github.io/helm-charts 2>/dev/null || true
helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null || true
helm repo update

kubectl create namespace monitoring 2>/dev/null || true

helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring --version 65.5.0 \
  --set prometheus.prometheusSpec.resources.requests.memory=400Mi \
  --set prometheus.prometheusSpec.resources.limits.memory=800Mi \
  --set grafana.resources.requests.memory=128Mi \
  --set grafana.resources.limits.memory=256Mi \
  --set alertmanager.alertmanagerSpec.resources.requests.memory=64Mi \
  --set alertmanager.alertmanagerSpec.resources.limits.memory=128Mi \
  --set prometheus.prometheusSpec.retention=2d \
  --set grafana.adminPassword=admin \
  --wait --timeout 5m

log "5/8 Installing Loki + Promtail"
helm install loki grafana/loki --namespace monitoring --version 6.16.0 \
  --set deploymentMode=SingleBinary \
  --set loki.auth_enabled=false \
  --set loki.commonConfig.replication_factor=1 \
  --set loki.storage.type=filesystem \
  --set loki.schemaConfig.configs[0].from=2024-01-01 \
  --set loki.schemaConfig.configs[0].store=tsdb \
  --set loki.schemaConfig.configs[0].object_store=filesystem \
  --set loki.schemaConfig.configs[0].schema=v13 \
  --set loki.schemaConfig.configs[0].index.prefix=index_ \
  --set loki.schemaConfig.configs[0].index.period=24h \
  --set singleBinary.replicas=1 \
  --set singleBinary.persistence.enabled=true \
  --set singleBinary.persistence.size=5Gi \
  --set backend.replicas=0 --set read.replicas=0 --set write.replicas=0 \
  --set monitoring.lokiCanary.enabled=false --set lokiCanary.enabled=false \
  --set test.enabled=false --set chunksCache.enabled=false \
  --set resultsCache.enabled=false --set gateway.enabled=false

helm install promtail grafana/promtail --namespace monitoring --version 6.16.6 \
  --set "config.clients[0].url=http://loki:3100/loki/api/v1/push" \
  --set "tolerations[0].operator=Exists"

log "6/8 Installing ArgoCD"
kubectl create namespace argocd 2>/dev/null || true
helm install argocd argo/argo-cd --namespace argocd --version 7.7.0 \
  --set server.service.type=ClusterIP --set dex.enabled=false \
  --wait --timeout 3m

log "7/8 Applying ArgoCD Applications"
kubectl apply -f gitops/argocd-apps/

log "8/8 Configuring Alertmanager webhook routing"
cat > ~/alertmanager-config.yaml <<AMEOF
apiVersion: v1
kind: Secret
metadata:
  name: alertmanager-kube-prometheus-stack-alertmanager
  namespace: monitoring
stringData:
  alertmanager.yaml: |
    global:
      resolve_timeout: 5m
    route:
      group_by: ['alertname', 'service']
      group_wait: 10s
      group_interval: 30s
      repeat_interval: 1h
      receiver: 'incident-service'
      routes:
        - matchers: [alertname = "Watchdog"]
          receiver: 'null'
        - matchers: [alertname = "InfoInhibitor"]
          receiver: 'null'
    receivers:
      - name: 'null'
      - name: 'incident-service'
        webhook_configs:
          - url: 'http://incident-service.default.svc.cluster.local/webhook/alert'
            send_resolved: true
AMEOF

kubectl apply -f ~/alertmanager-config.yaml
kubectl rollout restart statefulset/alertmanager-kube-prometheus-stack-alertmanager -n monitoring

log ""
log "Bootstrap complete. Now create the incident-service secret:"
log ""
log "  printf '%s' 'sk-ant-...' > ~/anthropic-key.txt"
log "  printf '%s' 'https://hooks.slack.com/services/...' > ~/slack-url.txt"
log "  kubectl create secret generic incident-service-secrets \\"
log "    --namespace=default \\"
log "    --from-file=ANTHROPIC_API_KEY=\$HOME/anthropic-key.txt \\"
log "    --from-file=SLACK_WEBHOOK_URL=\$HOME/slack-url.txt"
log "  rm ~/anthropic-key.txt ~/slack-url.txt"
log ""
log "Then force ArgoCD to sync apps that depend on the secret:"
log "  kubectl patch application incident-service -n argocd --type merge \\"
log "    -p '{\"metadata\":{\"annotations\":{\"argocd.argoproj.io/refresh\":\"hard\"}}}'"
