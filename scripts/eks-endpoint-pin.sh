#!/usr/bin/env bash
# Work around an EKS API endpoint IP that is unreachable from this network.
#
# The public EKS endpoint resolves to several IPs, returned in rotating order.
# If one is unreachable from here, every kubectl/helm call that happens to try it
# first waits ~16s before falling back. This script tests each IP and, ONLY if one
# is dead, pins the hostname to a reachable IP in /etc/hosts (tagged, so it can be
# removed cleanly). If all IPs answer, it changes nothing.
#
# Usage: eks-endpoint-pin.sh pin|unpin [cluster]
# Limit: AWS can move endpoint IPs during maintenance. A stale pin makes kubectl fail
# instead of being slow: run "unpin" (or "pin" again). Fine for short lab sessions.
set -euo pipefail

ACTION="${1:-pin}"
CLUSTER="${2:-platform}"
REGION="${AWS_REGION:-us-east-1}"
HOSTS_FILE="${HOSTS_FILE:-/etc/hosts}"   # overridable for testing
SUDO="${SUDO-sudo}"                     # set SUDO= when the file is writable
MARK="# eks-endpoint-pin:${CLUSTER}"

unpin() {
  if grep -qF "$MARK" "$HOSTS_FILE"; then
    # Rewrite through a temp file: only lines carrying our marker are removed
    tmp=$(mktemp)
    grep -vF "$MARK" "$HOSTS_FILE" > "$tmp" || true
    $SUDO cp "$tmp" "$HOSTS_FILE"; rm -f "$tmp"
    echo "endpoint pin for '$CLUSTER' removed"
  fi
}

case "$ACTION" in
  unpin) unpin; exit 0 ;;
  pin) ;;
  *) echo "usage: $0 pin|unpin [cluster]" >&2; exit 2 ;;
esac

unpin   # never test through an old pin

host="${EKS_HOST:-$(aws eks describe-cluster --name "$CLUSTER" --region "$REGION" --query cluster.endpoint --output text)}"
host="${host#https://}"
[[ "$host" =~ ^[A-Za-z0-9.-]+$ ]] || { echo "unexpected endpoint: $host" >&2; exit 1; }

mapfile -t ips < <(if [ -n "${EKS_IPS:-}" ]; then tr ' ' '\n' <<< "$EKS_IPS"; else getent ahostsv4 "$host" | awk '{print $1}'; fi | sort -u)
[ "${#ips[@]}" -gt 0 ] || { echo "could not resolve $host" >&2; exit 1; }

good=(); bad=()
for ip in "${ips[@]}"; do
  # Any HTTP answer (even 401/403) proves the IP is reachable; 000 means it is not
  code=$(curl -sk --noproxy '*' -o /dev/null --connect-timeout 5 --max-time 10 --resolve "$host:443:$ip" \
           -w '%{http_code}' "https://$host/livez" || true)
  if [ "${code:-000}" != "000" ]; then good+=("$ip"); echo "  ✅ $ip reachable (HTTP $code)"
  else bad+=("$ip"); echo "  ❌ $ip unreachable"; fi
done

if [ "${#bad[@]}" -eq 0 ]; then
  echo "all ${#good[@]} endpoint IPs reachable: no pin needed"
elif [ "${#good[@]}" -eq 0 ]; then
  echo "no endpoint IP is reachable: check admin_cidr (your IP may have changed) or the network" >&2
  exit 1
else
  echo "${good[0]} $host $MARK" | $SUDO tee -a "$HOSTS_FILE" >/dev/null
  echo "pinned $host -> ${good[0]} (avoids ${bad[*]}); remove with: $0 unpin $CLUSTER"
fi
