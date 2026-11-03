#!/usr/bin/env bash
# Scan every region for resources that cost money by the hour.
set -uo pipefail
export AWS_PROFILE="${AWS_PROFILE:-study}"
echo "Account: $(aws sts get-caller-identity --query Account --output text)"

check_region() {
  r=$1; out=""
  n=$(aws ec2 describe-instances --region "$r" --filters Name=instance-state-name,Values=running,pending,stopped --query 'length(Reservations[].Instances[])' --output text); [ "$n" != "0" ] && out+=" EC2=$n"
  n=$(aws ec2 describe-nat-gateways --region "$r" --filter Name=state,Values=available,pending --query 'length(NatGateways)' --output text); [ "$n" != "0" ] && out+=" NAT=$n"
  n=$(aws ec2 describe-addresses --region "$r" --query 'length(Addresses)' --output text); [ "$n" != "0" ] && out+=" EIP=$n"
  n=$(aws ec2 describe-volumes --region "$r" --query 'length(Volumes)' --output text); [ "$n" != "0" ] && out+=" EBS=$n"
  n=$(aws elbv2 describe-load-balancers --region "$r" --query 'length(LoadBalancers)' --output text 2>/dev/null || echo 0); [ "$n" != "0" ] && out+=" LB=$n"
  n=$(aws eks list-clusters --region "$r" --query 'length(clusters)' --output text 2>/dev/null || echo 0); [ "$n" != "0" ] && out+=" EKS=$n"
  n=$(aws rds describe-db-instances --region "$r" --query 'length(DBInstances)' --output text 2>/dev/null || echo 0); [ "$n" != "0" ] && out+=" RDS=$n"
  n=$(aws ec2 describe-vpc-endpoints --region "$r" --filters Name=vpc-endpoint-type,Values=Interface --query 'length(VpcEndpoints)' --output text); [ "$n" != "0" ] && out+=" VPCE=$n"
  if [ -n "$out" ]; then echo "⚠️  $r:$out"; else echo "  ✓ $r"; fi
}
export -f check_region

results=$(aws ec2 describe-regions --query 'Regions[].RegionName' --output text | tr '\t' '\n' \
  | xargs -P 8 -I{} bash -c 'check_region "$1"' _ {})
echo "$results" | sort
found=0; grep -q '⚠️' <<< "$results" && found=1

echo
if [ "$found" -eq 0 ]; then echo "✅ nothing billable running in any region"; else echo "❌ billable resources found (see ⚠️ lines)"; fi
[ "$found" -eq 0 ]
