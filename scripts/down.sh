#!/usr/bin/env bash
set -euo pipefail
export AWS_PROFILE="${AWS_PROFILE:-study}"
ROOT="$(git rev-parse --show-toplevel)"

echo "== Checking for AWS resources created by Kubernetes"
if kubectl get svc -A 2>/dev/null | grep -q LoadBalancer || [ -n "$(kubectl get pvc -A -o name 2>/dev/null)" ]; then
  echo "LoadBalancer services or PVCs exist. Delete them first, or the VPC destroy will fail."
  exit 1
fi

cd "$ROOT/infra/eks"
terraform destroy
rm -f eks.tfplan

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
kubectl config delete-context "arn:aws:eks:us-east-1:${ACCOUNT_ID}:cluster/platform" 2>/dev/null || true
echo "Destroyed. Run the cleanup checks to confirm nothing billable is left."
