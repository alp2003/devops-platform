#!/usr/bin/env bash
# Proves the access model in infra/eks/access.tf on the live cluster.
#
# For each role (admin, developer, viewer) it adds a kubeconfig context that assumes the
# role, then asks the API server what that role may do (kubectl auth can-i) and compares
# the answer with the expected one. Allowed AND denied cases are both tested: a check
# that only tests "allowed" can't catch a role that has too much access.
#
# Usage: ./scripts/access-check.sh      Exit code: 0 = all as expected, 1 = mismatch.
set -uo pipefail

CLUSTER=platform
REGION=us-east-1
PROFILE=${AWS_PROFILE:-study}
ACCOUNT=$(aws sts get-caller-identity --query Account --output text --profile "$PROFILE") || exit 1

PASS=0; FAIL=0
original_ctx=$(kubectl config current-context)
trap 'kubectl config use-context "$original_ctx" >/dev/null' EXIT

# Context AND user named platform-<role>. --user-alias matters: without it every context
# shares one user entry named after the cluster ARN, so each call overwrites the previous
# role (and your own admin context). update-kubeconfig switches the current context; the
# trap above switches back.
for role in admin developer viewer; do
  aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER" --profile "$PROFILE" \
    --role-arn "arn:aws:iam::${ACCOUNT}:role/${CLUSTER}-${role}" \
    --alias "platform-${role}" --user-alias "platform-${role}" >/dev/null \
    || { echo "❌ cannot add context for ${role}"; exit 1; }
done

# Nodes are cluster-scoped: Kubernetes 'view' (and so AmazonEKSViewPolicy) doesn't include them.
# role      expected  verb    resource              namespace (- = cluster scope)
matrix='
admin      yes  create  clusterrolebindings   -
admin      yes  get     secrets               monitoring
admin      yes  delete  pods                  web-prod
developer  yes  create  deployments           web-dev
developer  yes  delete  pods                  web-dev
developer  yes  get     pods/log              web-dev
developer  yes  get     pods                  web-prod
developer  no   delete  pods                  web-prod
developer  no   patch   deployments           web-prod
developer  no   get     pods                  monitoring
developer  no   get     secrets               web-prod
developer  no   create  rolebindings          web-dev
developer  no   get     nodes                 -
viewer     yes  get     pods                  web-prod
viewer     yes  list    deployments           kyverno
viewer     no   get     nodes                 -
viewer     no   get     secrets               monitoring
viewer     no   delete  pods                  web-dev
viewer     no   create  pods/exec             web-prod
viewer     no   create  clusterrolebindings   -
'

current=""
while read -r role want verb resource ns; do
  [ -z "$role" ] && continue
  if [ "$role" != "$current" ]; then
    current=$role
    who=$(kubectl --context "platform-${role}" auth whoami -o jsonpath='{.status.userInfo.username}' 2>/dev/null)
    echo; echo "== ${role} (${who:-unknown})"
    # Guard: the answers below only mean something if the context really is this role
    if [[ $who != *":assumed-role/${CLUSTER}-${role}/"* ]]; then
      echo "  ❌ context platform-${role} is not authenticated as role ${CLUSTER}-${role}"; FAIL=$((FAIL + 1))
    else
      echo "  ✅ authenticated as role ${CLUSTER}-${role}"; PASS=$((PASS + 1))
    fi
  fi
  args=("$verb" "${resource%/*}")
  [[ $resource == */* ]] && args+=(--subresource "${resource#*/}") # "pods/log" = pods, subresource log
  [ "$ns" != "-" ] && args+=(-n "$ns")
  got=$(kubectl --context "platform-${role}" auth can-i "${args[@]}" 2>/dev/null)
  where=${ns/#-/cluster}
  if [ "$got" = "$want" ]; then
    echo "  ✅ ${verb} ${resource} in ${where}: ${got}"; PASS=$((PASS + 1))
  else
    echo "  ❌ ${verb} ${resource} in ${where}: got '${got:-error}', expected ${want}"; FAIL=$((FAIL + 1))
  fi
done <<< "$matrix"

echo
echo "Access checks: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
