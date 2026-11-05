#!/usr/bin/env bash
set -euo pipefail
export AWS_PROFILE="${AWS_PROFILE:-study}"
ROOT="$(git rev-parse --show-toplevel)"

# Phase timing: shows where the ~20 minutes go (mostly AWS creating EKS, then the sync waves)
T0=$SECONDS; TP=$SECONDS; TIMES=()
phase_done() { TIMES+=("$(printf '%-28s %3dm%02ds' "$1" $(((SECONDS - TP) / 60)) $(((SECONDS - TP) % 60)))"); TP=$SECONDS; }

# Fail fast, before spending anything: the cluster's secrets must already exist in SSM
missing=$(aws ssm get-parameters --region us-east-1 \
  --names /devops-platform/telegram-bot-token /devops-platform/grafana-admin-password \
  --query 'InvalidParameters' --output text)
if [ -n "$missing" ] && [ "$missing" != "None" ]; then
  echo "Missing SSM parameters: $missing"
  echo "Run scripts/secrets-init.sh once, then run up.sh again."
  exit 1
fi

# The EKS API only accepts this IP: refuse to continue with an empty or garbled answer
my_ip=$(curl -fsS --max-time 10 https://checkip.amazonaws.com | tr -d '[:space:]')
[[ "$my_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || { echo "Could not determine your public IP (got '${my_ip}')."; exit 1; }

echo "== 1/5 Terraform: VPC + EKS"
cd "$ROOT/infra/eks"
echo "admin_cidr = \"${my_ip}/32\"" > terraform.tfvars
terraform init -input=false
terraform plan -out=eks.tfplan -no-color | grep -E '^Plan:'
read -rp "Apply this plan? (yes/no) " ok
[ "$ok" = "yes" ] || { echo "Aborted."; exit 1; }
TP=$SECONDS; T0=$SECONDS   # don't count the time spent reading the plan
terraform apply eks.tfplan
phase_done "Terraform (VPC + EKS)"

echo "== 2/5 kubeconfig"
aws eks update-kubeconfig --region us-east-1 --name platform --profile study
# Pin the API hostname to a reachable IP, only if one endpoint IP is dead (see the script)
"$ROOT/scripts/eks-endpoint-pin.sh" pin platform
phase_done "kubeconfig + endpoint check"

echo "== 3/5 ArgoCD"
cd "$ROOT"
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo update argo >/dev/null   # a stale local index can miss the pinned chart version
helm upgrade --install argocd argo/argo-cd --version 10.11.6 \
  -n argocd --create-namespace -f platform/bootstrap/argocd-values.yaml --wait --timeout 10m
phase_done "ArgoCD"

# Platform secrets come from SSM Parameter Store via External Secrets (platform/secrets).
echo "== 4/5 Root application"
kubectl apply -f platform/root.yaml

# EKS often publishes the second endpoint IP a minute or two after creation:
# check again now that both exist (no-op when every IP answers)
"$ROOT/scripts/eks-endpoint-pin.sh" pin platform

echo "== 5/5 Waiting for every app to be Healthy (sync waves -2 .. 2)"
# root is Healthy only when all its child apps are (Application health check in argocd-values.yaml)
if kubectl wait application/root -n argocd --for=jsonpath='{.status.health.status}'=Healthy --timeout=30m; then
  phase_done "Platform apps (all waves)"
else
  echo "Not all apps became Healthy within 30 minutes. Still waiting:"
  kubectl get applications -n argocd | grep -vE 'Synced +Healthy' || true
  exit 1
fi

echo
echo "== Timing"
printf '  %s\n' "${TIMES[@]}"
printf '  %-28s %3dm%02ds\n' "Total (after 'yes')" $(((SECONDS - T0) / 60)) $(((SECONDS - T0) % 60))
echo
echo "Platform is up. Run ./scripts/verify.sh in ~5 minutes (install-time noise settles)."
echo "ArgoCD admin password: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo"
