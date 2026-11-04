#!/usr/bin/env bash
# pass/warn/fail always return 0, so the "A && pass || fail" pattern is safe here.
# shellcheck disable=SC2015
# Post-deploy verification for the devops-platform cluster (kind or EKS).
# Checks that every component is not just "Healthy" but actually doing its job.
# Exit code: 0 = all checks passed (warnings allowed), 1 = at least one failure.
# Run it ~5 minutes after every ArgoCD app is Synced/Healthy: install-time noise (hook jobs,
# the operator's webhook certificate race) is gone by then. See README.md.
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

# A pod counts as broken if it is not Running/Succeeded, EXCEPT:
#  - Job pods (Helm hooks, one-off tasks) younger than 5 min: they are meant to start and
#    stop. A FAILED Job pod, or one stuck for 5+ min, still counts.
#  - pods younger than 60s: they are still being scheduled or pulling their image.
# Those are listed as "starting" for information, without failing the run.
# shellcheck disable=SC2016  # $now is a jq variable, not a shell one
pod_filter='.items[]
  | select(.status.phase != "Running" and .status.phase != "Succeeded")
  | ([.metadata.ownerReferences[]?.kind] | index("Job") != null) as $job
  | ($now - (.metadata.creationTimestamp | fromdateiso8601)) as $age
  | if ($job and .status.phase != "Failed" and $age < 300) or $age < 60
    then (if $want == "starting" then "\(.metadata.namespace)/\(.metadata.name) \(.status.phase) (\($age)s\(if $job then ", job" else "" end))" else empty end)
    else (if $want == "bad" then "\(.metadata.namespace)/\(.metadata.name) \(.status.phase)" else empty end)
    end'
pods_json=$(kubectl get pods -A -o json)
now=$(date -u +%s)
bad_pods=$(jq -r --argjson now "$now" --arg want bad "$pod_filter" <<< "$pods_json")
starting=$(jq -r --argjson now "$now" --arg want starting "$pod_filter" <<< "$pods_json")
[ -z "$bad_pods" ] && pass "all pods Running/Completed" || { fail "pods not running:"; indent <<< "$bad_pods"; }
[ -z "$starting" ] || { echo "  · still starting (not counted):"; indent <<< "$starting"; }

unready=$(kubectl get pods -A --no-headers | awk '$4=="Running" {split($3,a,"/"); if (a[1]!=a[2]) print $1"/"$2" "$3}')
[ -z "$unready" ] && pass "all running containers ready" || { fail "containers not ready:"; indent <<< "$unready"; }

restarts=$(kubectl get pods -A --no-headers | awk '$5 > 0 {print $1"/"$2" restarts="$5}')
[ -z "$restarts" ] && pass "no container restarts" || { warn "pods with restarts (check if recent):"; indent <<< "$restarts"; }

# ---------------------------------------------------------------- api endpoint
section "API endpoint"
# Every IP the API name resolves to must answer; one dead IP makes ~half of all kubectl calls hang ~16s.
api_host=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}'); api_host="${api_host#https://}"
if [[ "$api_host" == *.eks.amazonaws.com ]] && command -v dig >/dev/null; then
  # dig asks DNS directly, so the real IPs are tested even when /etc/hosts pins one
  mapfile -t api_ips < <(dig +short "$api_host" | grep -E '^[0-9.]+$' | sort -u)
  dead=()
  for ip in "${api_ips[@]}"; do
    code=$(curl -sk --noproxy '*' -o /dev/null --connect-timeout 5 --max-time 10 --resolve "$api_host:443:$ip" \
      -w '%{http_code}' "https://$api_host/livez" || true)
    [ "${code:-000}" = "000" ] && dead+=("$ip")
  done
  if [ "${#api_ips[@]}" -eq 0 ]; then
    fail "could not resolve $api_host"
  elif [ "${#dead[@]}" -eq 0 ]; then
    pass "all ${#api_ips[@]} endpoint IPs reachable"
  elif grep -q 'eks-endpoint-pin:' /etc/hosts; then
    warn "unreachable endpoint IP(s) ${dead[*]}, handled by the /etc/hosts pin"
  else
    fail "unreachable endpoint IP(s) ${dead[*]}: run scripts/eks-endpoint-pin.sh pin"
  fi
else
  warn "skipped endpoint IP check (not EKS, or 'dig' missing)"
fi

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
section "Web app"
# The chain we prove, per environment:
#   git (ArgoCD Synced, above) -> Deployment pins a digest -> every pod runs exactly that digest
#   -> the image is signed by our release workflow for that version -> the app reports that version
SIGNER="https://github.com/alp2003/devops-platform/.github/workflows/release.yaml@refs/tags/v"
port=18080
for env in dev prod; do
  ns="web-$env"
  image=$(kubectl get deploy web -n "$ns" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)
  if [ -z "$image" ]; then fail "$ns: deployment/web not found"; port=$((port + 1)); continue; fi
  want_ver=$(kubectl get deploy web -n "$ns" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/version}')
  digest="${image##*@}"

  if [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
    pass "$ns: deployment pins ${want_ver} by digest (${digest:7:12}…)"
  else
    fail "$ns: image not pinned by digest: $image"
  fi

  # What the kubelet actually pulled, per pod. Must equal the pinned digest.
  ids=$(kubectl get pods -n "$ns" -l app=web -o jsonpath='{range .items[*]}{.metadata.name} {.status.containerStatuses[0].imageID}{"\n"}{end}')
  npods=$(grep -c . <<< "$ids" || true)
  wrong=$(awk -v d="$digest" 'NF && $2 !~ ("@" d "$") {print $1" runs "$2}' <<< "$ids")
  [ "$npods" -gt 0 ] && [ -z "$wrong" ] && pass "$ns: $npods/$npods pods run exactly that digest" \
    || { fail "$ns: pods not running the pinned digest:"; indent <<< "${wrong:-no pods}"; }

  # Signature: issued to our release workflow, for THIS version's tag (needs cosign + ECR access)
  repo="${image%@*}"; repo="${repo%:*}"   # strip @digest, then :tag (works with or without a tag)
  if command -v cosign >/dev/null; then
    if [ -z "${ECR_LOGIN_DONE:-}" ]; then
      aws ecr get-login-password --region us-east-1 2>/dev/null \
        | docker login --username AWS --password-stdin "${repo%%/*}" >/dev/null 2>&1
      ECR_LOGIN_DONE=1
    fi
    if cosign verify "${repo}@${digest}" \
         --certificate-identity "${SIGNER}${want_ver}" \
         --certificate-oidc-issuer https://token.actions.githubusercontent.com >/dev/null 2>&1; then
      pass "$ns: signature valid, signed by release.yaml@v${want_ver}"
    else
      fail "$ns: cosign verify failed for v${want_ver} (signature, identity, or ECR login)"
    fi
  else
    warn "$ns: cosign not installed, signature not checked"
  fi

  if pf "$ns" web "$port" 80; then
    root=$(curl -s "http://localhost:$port/")
    got_env=$(jq -r '.environment // empty' <<< "$root" 2>/dev/null)
    got_ver=$(jq -r '.version // empty' <<< "$root" 2>/dev/null)
    [ "$got_ver" = "$want_ver" ] && [ "$got_env" = "$env" ] \
      && pass "$ns: GET / → version=$got_ver environment=$got_env" \
      || fail "$ns: GET / → '${root:-no response}' (want version=$want_ver environment=$env)"
    code=$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:$port/healthz")
    [ "$code" = "200" ] && pass "$ns: /healthz → 200" || fail "$ns: /healthz → $code"
    metrics=$(curl -s "http://localhost:$port/metrics")
    grep -q "^web_build_info{.*version=\"$want_ver\"" <<< "$metrics" \
      && pass "$ns: /metrics exposes web_build_info version=$want_ver" \
      || fail "$ns: web_build_info missing or wrong version in /metrics"
  else
    fail "$ns: could not port-forward to svc/web"
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

ivp=$(kubectl get imagevalidatingpolicy require-release-signature -o name 2>/dev/null)
[ -n "$ivp" ] && pass "signature policy installed: require-release-signature (Deny)" || fail "ImageValidatingPolicy require-release-signature not found"

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
recon=$(kubectl get prometheus -n monitoring -o jsonpath='{.items[0].status.conditions[?(@.type=="Reconciled")].status}' 2>/dev/null)
[ "$recon" = "True" ] && pass "Prometheus resource reconciled by the operator" \
  || fail "Prometheus resource not reconciled (operator started before its CRDs? check its log for 'not installed')"
if pf monitoring kps-kube-prometheus-stack-prometheus 19090 9090; then
  down=$(curl -s 'http://localhost:19090/api/v1/query?query=up==0' | jq -r '.data.result[] | "\(.metric.job) \(.metric.instance)"')
  up=$(curl -s 'http://localhost:19090/api/v1/query?query=count(up==1)' | jq -r '.data.result[0].value[1] // 0')
  [ -z "$down" ] && pass "$up targets up, 0 down" || { fail "targets down:"; indent <<< "$down"; }
  rules=$(curl -s http://localhost:19090/api/v1/rules | jq '[.data.groups[].rules[]] | length')
  [ "$rules" -gt 0 ] && pass "$rules alerting/recording rules loaded" || fail "no rules loaded"
  firing=$(curl -s http://localhost:19090/api/v1/alerts | jq -r '.data.alerts[] | select(.state=="firing") | .labels.alertname' | sort -u)
  grep -qx Watchdog <<< "$firing" && pass "Watchdog firing (alert pipeline alive)" || fail "Watchdog not firing"
  # The app itself is scraped, and Prometheus sees the version each environment runs
  for ns in web-dev web-prod; do
    want=$(kubectl get deploy web -n "$ns" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/version}' 2>/dev/null)
    ups=$(curl -s -G http://localhost:19090/api/v1/query --data-urlencode "query=sum(up{namespace=\"$ns\",service=\"web\"})" | jq -r '.data.result[0].value[1] // 0')
    seen=$(curl -s -G http://localhost:19090/api/v1/query --data-urlencode "query=web_build_info{namespace=\"$ns\"}" | jq -r '[.data.result[].metric.version] | unique | join(",")')
    [ "$ups" -gt 0 ] && [ "$seen" = "$want" ] && pass "$ns: $ups app target(s) scraped, web_build_info version=$seen" \
      || fail "$ns: app scrape: up=$ups, web_build_info version='${seen}' (want $want)"
  done
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
    # End-to-end: push a test alert and watch Alertmanager's per-request counters for Telegram.
    #  - requests_failed_total rises on EVERY failed attempt (e.g. bad token -> 404), unlike
    #    notifications_failed_total, which waits until all retries are exhausted (minutes).
    #  - a unique namespace label puts each run in its own alert group, so a run shortly
    #    after another is not deduplicated into the still-active alert.
    metric() { curl -s http://localhost:19093/metrics | awk -v m="$1" '$1 ~ "^"m"\\{.*integration=\"telegram\"" {s+=$2} END {print s+0}'; }
    req_before=$(metric alertmanager_notification_requests_total)
    bad_before=$(metric alertmanager_notification_requests_failed_total)
    run="verify-$(date +%s)"
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ); ends=$(date -u -d '+3 minutes' +%Y-%m-%dT%H:%M:%SZ)
    curl -s -o /dev/null -XPOST -H 'Content-Type: application/json' http://localhost:19093/api/v2/alerts \
      -d "[{\"labels\":{\"alertname\":\"VerifyTestAlert\",\"severity\":\"warning\",\"namespace\":\"$run\"},\"annotations\":{\"summary\":\"End-to-end test from verify.sh at $now\"},\"startsAt\":\"$now\",\"endsAt\":\"$ends\"}]"
    ok=0; bad=0
    for _ in $(seq 1 30); do   # group_wait is 30s, so allow up to 60s
      sleep 2
      req=$(( $(metric alertmanager_notification_requests_total) - req_before ))
      bad=$(( $(metric alertmanager_notification_requests_failed_total) - bad_before ))
      ok=$(( req - bad ))
      [ "$ok" -gt 0 ] || [ "$bad" -gt 0 ] && break
    done
    if [ "$ok" -gt 0 ] && [ "$bad" -eq 0 ]; then
      pass "test alert accepted by Telegram ($run, check the group)"
    elif [ "$bad" -gt 0 ]; then
      err=$(kubectl logs -n monitoring alertmanager-kps-kube-prometheus-stack-alertmanager-0 -c alertmanager --since=2m 2>/dev/null \
        | grep -o 'err="telegram[^"]*"' | tail -1)
      fail "Telegram rejected the test alert: ${err:-see alertmanager logs} (bad token? recreate monitoring/alertmanager-telegram)"
    else
      fail "test alert not sent within 60s ($run)"
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

# ---------------------------------------------------------------- external secrets
section "External Secrets"
store=$(kubectl get clustersecretstore aws-parameter-store -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
[ "$store" = "True" ] && pass "ClusterSecretStore aws-parameter-store Ready (Pod Identity → SSM)" \
  || fail "ClusterSecretStore aws-parameter-store not Ready: $(kubectl get clustersecretstore aws-parameter-store -o jsonpath='{.status.conditions[0].message}' 2>/dev/null)"
es_json=$(kubectl get externalsecret -A -o json 2>/dev/null || echo '{"items":[]}')
n_es=$(jq '.items | length' <<< "$es_json")
not_synced=$(jq -r '.items[] | select(([.status.conditions[]? | select(.type=="Ready" and .status=="True")] | length) == 0)
  | "\(.metadata.namespace)/\(.metadata.name): \([.status.conditions[]?.message] | join("; "))"' <<< "$es_json")
[ "$n_es" -gt 0 ] && [ -z "$not_synced" ] && pass "$n_es/$n_es ExternalSecrets synced from Parameter Store" \
  || { fail "ExternalSecrets not synced (${n_es} found):"; indent <<< "${not_synced:-none}"; }

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
  dash=$(curl -s -u "admin:$gpass" "http://localhost:13000/api/dashboards/uid/web-releases" | jq -r '.dashboard.title // empty')
  [ -n "$dash" ] && pass "dashboard '$dash' provisioned" || fail "dashboard web-releases not found (dashboards app / Grafana sidecar)"
else
  fail "could not reach Grafana"
fi
unset gpass

# ---------------------------------------------------------------- error logs
section "Errors in platform logs (last 10 min, informational)"
# One API call lists the pods, then 8 log reads run in parallel, each with a timeout.
# Sequentially this took ~11 min on EKS (one slow round trip per pod).
scan_pod_errors() { # namespace pod
  local n
  n=$(kubectl logs -n "$1" "$2" --all-containers --since=10m --request-timeout=20s 2>/dev/null \
    | grep -ciE 'level=(error|fatal|panic)|"level": ?"(error|fatal|panic)"|^E[0-9]{4} ' || true)
  [ "${n:-0}" -gt 0 ] && echo "  · $1/$2: $n error lines"
  return 0
}
export -f scan_pod_errors
pods=$(kubectl get pods -A --field-selector=status.phase=Running \
  -o jsonpath='{range .items[*]}{.metadata.namespace} {.metadata.name}{"\n"}{end}' \
  | awk '$1 ~ /^(argocd|kyverno|falco|monitoring|web-dev|web-prod)$/')
# shellcheck disable=SC2016  # $1/$2 are expanded by the inner bash, not here
errors=$(xargs -r -P 8 -L 1 bash -c 'scan_pod_errors "$1" "$2"' _ <<< "$pods" | sort)
[ -z "$errors" ] && echo "  ✅ no error-level log lines ($(grep -c . <<< "$pods") pods scanned)" || echo "$errors"

# ---------------------------------------------------------------- summary
echo
echo "== Summary: $PASS passed, $WARN warnings, $FAIL failed"
[ "$FAIL" -eq 0 ]
