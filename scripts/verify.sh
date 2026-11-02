#!/usr/bin/env bash
# pass/warn/fail always return 0, so the "A && pass || fail" pattern is safe here.
# shellcheck disable=SC2015
# Post-deploy verification for the devops-platform cluster (kind or EKS).
# Checks that every component is not just "Healthy" but actually doing its job.
# Exit code: 0 = all checks passed (warnings allowed), 1 = at least one failure.
set -uo pipefail

PASS=0; FAIL=0; WARN=0
PF_PIDS=()

pass() { echo "  ✅ $*"; PASS=$((PASS + 1)); return 0; }
fail() { echo "  ❌ $*"; FAIL=$((FAIL + 1)); return 0; }
warn() { echo "  ⚠️  $*"; WARN=$((WARN + 1)); return 0; }
indent() { sed 's/^/       /'; }
section() { echo; echo "== $*"; }

cleanup() { for p in "${PF_PIDS[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done; }
trap cleanup EXIT

# Port-forward a service in the background and wait until it answers.
pf() { # namespace service local_port remote_port
  kubectl port-forward -n "$1" "svc/$2" "$3:$4" >/dev/null 2>&1 &
  PF_PIDS+=($!)
  for _ in $(seq 1 30); do
    curl -s -o /dev/null "http://localhost:$3" && return 0
    sleep 0.5
  done
  return 1
}

echo "Verifying cluster: $(kubectl config current-context)"

# ---------------------------------------------------------------- cluster
section "Cluster"
not_ready=$(kubectl get nodes --no-headers | awk '$2 != "Ready"' | wc -l)
total=$(kubectl get nodes --no-headers | wc -l)
[ "$not_ready" -eq 0 ] && pass "$total/$total nodes Ready" || fail "$not_ready node(s) not Ready"

bad_pods=$(kubectl get pods -A --no-headers | grep -vE 'Running|Completed' || true)
[ -z "$bad_pods" ] && pass "all pods Running/Completed" || { fail "pods not running:"; indent <<< "$bad_pods"; }

unready=$(kubectl get pods -A --no-headers | awk '$4=="Running" {split($3,a,"/"); if (a[1]!=a[2]) print $1"/"$2" "$3}')
[ -z "$unready" ] && pass "all running containers ready" || { fail "containers not ready:"; indent <<< "$unready"; }

restarts=$(kubectl get pods -A --no-headers | awk '$5 > 0 {print $1"/"$2" restarts="$5}')
[ -z "$restarts" ] && pass "no container restarts" || { warn "pods with restarts (check if recent):"; indent <<< "$restarts"; }

# ---------------------------------------------------------------- argocd
section "ArgoCD"
apps=$(kubectl get applications -n argocd -o json)
napps=$(echo "$apps" | jq '.items | length')
bad_apps=$(echo "$apps" | jq -r '.items[] | select(.status.sync.status != "Synced" or .status.health.status != "Healthy") | "\(.metadata.name) sync=\(.status.sync.status) health=\(.status.health.status)"')
[ -z "$bad_apps" ] && pass "$napps/$napps applications Synced/Healthy" || { fail "applications not Synced/Healthy:"; indent <<< "$bad_apps"; }
# For any OutOfSync app, show exactly which resources differ
for app in $(echo "$apps" | jq -r '.items[] | select(.status.sync.status != "Synced") | .metadata.name'); do
  echo "$apps" | jq -r --arg a "$app" '.items[] | select(.metadata.name==$a) | .status.resources[]? | select(.status != "Synced") | "       ↳ \($a): \(.kind)/\(.name) \(.status)"'
done

# ---------------------------------------------------------------- web app
section "Web app (HTTP)"
port=18080
for ns in web-dev web-prod; do
  svc=$(kubectl get svc -n "$ns" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  svc_port=$(kubectl get svc -n "$ns" -o jsonpath='{.items[0].spec.ports[0].port}' 2>/dev/null)
  if [ -z "$svc" ]; then fail "$ns: no Service found"; continue; fi
  if pf "$ns" "$svc" "$port" "$svc_port"; then
    code=$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:$port/")
    [ "$code" = "200" ] && pass "$ns: GET / → $code" || fail "$ns: GET / → $code"
  else
    fail "$ns: could not port-forward to svc/$svc"
  fi
  port=$((port + 1))
done

# ---------------------------------------------------------------- kyverno
section "Kyverno"
not_ready_pol=$(kubectl get clusterpolicy -o json 2>/dev/null | jq -r '.items[] | select((.status.conditions // [] | map(select(.type=="Ready" and .status=="True")) | length) == 0) | .metadata.name')
npol=$(kubectl get clusterpolicy --no-headers 2>/dev/null | wc -l)
[ "$npol" -gt 0 ] && [ -z "$not_ready_pol" ] && pass "$npol policies Ready" || fail "policies not ready: ${not_ready_pol:-none found}"

adm=$(kubectl get deploy -n kyverno kyverno-admission-controller -o jsonpath='{.status.readyReplicas}/{.spec.replicas}' 2>/dev/null)
[ "${adm%/*}" = "${adm#*/}" ] && [ "${adm%/*}" -ge 2 ] 2>/dev/null && pass "admission controller HA: $adm ready" || warn "admission controller replicas: ${adm:-unknown}"

warnings=$(kubectl run verify-kyverno -n web-dev --image=busybox:latest --dry-run=server -o name \
  --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":10001,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"verify-kyverno","image":"busybox:latest","securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}]}}' 2>&1 \
  | grep -c '^Warning: policy' || true)
[ "$warnings" -ge 3 ] && pass "webhook active: bad pod in web-dev → $warnings policy warnings" || fail "webhook test: expected ≥3 policy warnings, got $warnings"

reports=$(kubectl get policyreport -A --no-headers 2>/dev/null | wc -l)
[ "$reports" -gt 0 ] && pass "$reports PolicyReports generated" || fail "no PolicyReports found"

# ---------------------------------------------------------------- falco
section "Falco"
ds=$(kubectl get ds -n falco falco -o jsonpath='{.status.numberReady}/{.status.desiredNumberScheduled}' 2>/dev/null)
[ -n "$ds" ] && [ "${ds%/*}" = "${ds#*/}" ] && pass "running on every node: $ds" || fail "falco daemonset: ${ds:-not found}"

pod=$(kubectl get pod -n web-dev -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -n "$pod" ] && command -v script >/dev/null; then
  marker="verify-$(date +%s)"
  # 'script' allocates a pseudo-terminal so 'kubectl exec -it' works from a script
  script -qec "kubectl exec -it -n web-dev $pod -- sh -c 'echo $marker'" /dev/null >/dev/null 2>&1
  found=0
  for _ in $(seq 1 30); do   # up to 60s: Falco output is not instant under load
    # Capture first, then grep: with pipefail, "kubectl | grep -q" can report a match as a failure (SIGPIPE)
    falco_logs=$(kubectl logs -n falco -l app.kubernetes.io/name=falco -c falco --since=2m --tail=-1 2>/dev/null)
    if grep -q "$marker" <<< "$falco_logs"; then found=1; break; fi
    sleep 2
  done
  [ "$found" -eq 1 ] && pass "detected a terminal shell in web-dev ($marker)" || fail "no Falco alert for test shell ($marker)"
else
  warn "skipped detection test (no web-dev pod or 'script' command)"
fi

# ---------------------------------------------------------------- prometheus
section "Prometheus"
if pf monitoring kps-kube-prometheus-stack-prometheus 19090 9090; then
  down=$(curl -s 'http://localhost:19090/api/v1/query?query=up==0' | jq -r '.data.result[] | "\(.metric.job) \(.metric.instance)"')
  up=$(curl -s 'http://localhost:19090/api/v1/query?query=count(up==1)' | jq -r '.data.result[0].value[1] // 0')
  [ -z "$down" ] && pass "$up targets up, 0 down" || { fail "targets down:"; indent <<< "$down"; }
  rules=$(curl -s http://localhost:19090/api/v1/rules | jq '[.data.groups[].rules[]] | length')
  [ "$rules" -gt 0 ] && pass "$rules alerting/recording rules loaded" || fail "no rules loaded"
  firing=$(curl -s http://localhost:19090/api/v1/alerts | jq -r '.data.alerts[] | select(.state=="firing") | .labels.alertname' | sort -u)
  grep -qx Watchdog <<< "$firing" && pass "Watchdog firing (alert pipeline alive)" || fail "Watchdog not firing"
  others=$(echo "$firing" | grep -vxE 'Watchdog|InfoInhibitor' || true)
  [ -z "$others" ] && pass "no other alerts firing" || { warn "other alerts firing:"; indent <<< "$others"; }
else
  fail "could not reach Prometheus"
fi

# ---------------------------------------------------------------- alertmanager
section "Alertmanager"
if pf monitoring kps-kube-prometheus-stack-alertmanager 19093 9093; then
  receivers=$(curl -s http://localhost:19093/api/v2/receivers | jq -r '.[].name' | grep -vx null || true)
  if [ -z "$receivers" ]; then
    warn "only the 'null' receiver: alerts are evaluated but delivered nowhere"
  else
    pass "receivers configured: $(tr '\n' ' ' <<< "$receivers")"
    # End-to-end: push a test alert and check that Alertmanager delivered it without errors
    metric() { curl -s http://localhost:19093/metrics | awk -v m="$1" '$1 ~ "^"m"\\{.*integration=\"telegram\"" {s+=$2} END {print s+0}'; }
    sent_before=$(metric alertmanager_notifications_total)
    failed_before=$(metric alertmanager_notifications_failed_total)
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ); ends=$(date -u -d '+3 minutes' +%Y-%m-%dT%H:%M:%SZ)
    curl -s -o /dev/null -XPOST -H 'Content-Type: application/json' http://localhost:19093/api/v2/alerts \
      -d "[{\"labels\":{\"alertname\":\"VerifyTestAlert\",\"severity\":\"warning\",\"namespace\":\"verify\"},\"annotations\":{\"summary\":\"End-to-end test from verify.sh at $now\"},\"startsAt\":\"$now\",\"endsAt\":\"$ends\"}]"
    delivered=0
    for _ in $(seq 1 30); do   # group_wait is 30s, so allow up to 60s
      sleep 2
      [ "$(metric alertmanager_notifications_total)" -gt "$sent_before" ] && { delivered=1; break; }
    done
    failed_after=$(metric alertmanager_notifications_failed_total)
    if [ "$delivered" -eq 1 ] && [ "$failed_after" -eq "$failed_before" ]; then
      pass "test alert delivered to Telegram (check your phone)"
    else
      fail "test alert not delivered (sent: $sent_before→$(metric alertmanager_notifications_total), failed: $failed_before→$failed_after)"
    fi
  fi
else
  fail "could not reach Alertmanager"
fi

# ---------------------------------------------------------------- loki
section "Loki"
if pf monitoring loki 13100 3100; then
  ns_list=$(curl -s -G http://localhost:13100/loki/api/v1/label/namespace/values | jq -r '.data[]?')
  for ns in web-prod kyverno falco; do
    grep -qx "$ns" <<< "$ns_list" && pass "receiving logs from $ns" || fail "no logs from $ns"
  done
else
  fail "could not reach Loki"
fi

# ---------------------------------------------------------------- grafana
section "Grafana"
gpass=$(kubectl get secret grafana-admin -n monitoring -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d)
if [ -z "$gpass" ]; then
  fail "secret monitoring/grafana-admin not found"
elif pf monitoring kps-grafana 13000 80; then
  login=$(curl -s -u "admin:$gpass" http://localhost:13000/api/user | jq -r '.login // empty')
  [ "$login" = "admin" ] && pass "admin login works (managed secret)" || fail "admin login failed"
  for uid in $(curl -s -u "admin:$gpass" http://localhost:13000/api/datasources | jq -r '.[].uid'); do
    ds_json=$(curl -s -u "admin:$gpass" "http://localhost:13000/api/datasources/uid/$uid")
    name=$(jq -r '.name' <<< "$ds_json"); type=$(jq -r '.type' <<< "$ds_json")
    if [ "$type" = "alertmanager" ]; then
      # Grafana has no health check for this type: query Alertmanager through Grafana's proxy instead
      code=$(curl -s -o /dev/null -w '%{http_code}' -u "admin:$gpass" "http://localhost:13000/api/datasources/proxy/uid/$uid/api/v2/status")
      [ "$code" = "200" ] && pass "datasource '$name' reachable via Grafana proxy" || fail "datasource '$name' proxy → HTTP $code"
    else
      health=$(curl -s -u "admin:$gpass" "http://localhost:13000/api/datasources/uid/$uid/health")
      status=$(jq -r '.status // "UNKNOWN"' <<< "$health")
      [ "$status" = "OK" ] && pass "datasource '$name' healthy" || fail "datasource '$name' status: $status ($(jq -r '.message // empty' <<< "$health"))"
    fi
  done
else
  fail "could not reach Grafana"
fi
unset gpass

# ---------------------------------------------------------------- error logs
section "Errors in platform logs (last 10 min, informational)"
found_errors=0
for ns in argocd kyverno falco monitoring; do
  for p in $(kubectl get pods -n "$ns" --field-selector=status.phase=Running -o name); do
    n=$(kubectl logs -n "$ns" "$p" --all-containers --since=10m 2>/dev/null \
      | grep -ciE 'level=(error|fatal|panic)|"level": ?"(error|fatal|panic)"|^E[0-9]{4} ' || true)
    if [ "$n" -gt 0 ]; then echo "  · $ns/${p#pod/}: $n error lines"; found_errors=1; fi
  done
done
[ "$found_errors" -eq 0 ] && echo "  ✅ no error-level log lines"

# ---------------------------------------------------------------- summary
echo
echo "== Summary: $PASS passed, $WARN warnings, $FAIL failed"
[ "$FAIL" -eq 0 ]
