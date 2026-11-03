#!/usr/bin/env bash
set -euo pipefail
export AWS_PROFILE="${AWS_PROFILE:-study}"
ROOT="$(git rev-parse --show-toplevel)"

echo "== 1/4 Terraform: VPC + EKS"
cd "$ROOT/infra/eks"
echo "admin_cidr = \"$(curl -s https://checkip.amazonaws.com)/32\"" > terraform.tfvars
terraform init -input=false
terraform plan -out=eks.tfplan -no-color | grep -E '^Plan:'
read -rp "Apply this plan? (yes/no) " ok
[ "$ok" = "yes" ] || { echo "Aborted."; exit 1; }
terraform apply eks.tfplan

echo "== 2/4 kubeconfig"
aws eks update-kubeconfig --region us-east-1 --name platform --profile study

echo "== 3/4 ArgoCD"
cd "$ROOT"
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm upgrade --install argocd argo/argo-cd --version 10.11.6 \
  -n argocd --create-namespace -f platform/bootstrap/argocd-values.yaml --wait --timeout 10m
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
kubectl get secret grafana-admin -n monitoring >/dev/null 2>&1 || \
  kubectl create secret generic grafana-admin -n monitoring \
    --from-literal=admin-user=admin \
    --from-literal=admin-password="$(openssl rand -base64 24)"
# Alertmanager mounts this secret (platform/apps/monitoring.yaml). Without it the pod can't start.
# The token is typed in (not echoed), never written to disk or Git.
if ! kubectl get secret alertmanager-telegram -n monitoring >/dev/null 2>&1; then
  read -rsp "Telegram bot token (from @BotFather): " tg_token; echo
  [ -n "$tg_token" ] || { echo "Empty token. Aborted."; exit 1; }
  kubectl create secret generic alertmanager-telegram -n monitoring \
    --from-literal=bot-token="$tg_token" >/dev/null
  unset tg_token
  echo "secret monitoring/alertmanager-telegram created"
fi
echo "== 4/4 Root application"
kubectl apply -f platform/root.yaml

echo "Done. ArgoCD admin password:"
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
