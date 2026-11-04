#!/usr/bin/env bash
# One-time setup of the platform's secrets in SSM Parameter Store (SecureString).
# They persist across clusters; External Secrets Operator syncs them into each new cluster.
#
#   scripts/secrets-init.sh                  create whatever is missing (idempotent)
#   scripts/secrets-init.sh --rotate-grafana   new random Grafana admin password
#   scripts/secrets-init.sh --rotate-telegram  replace the Telegram bot token
#
# Values never appear in Terraform state, in Git, on screen or in 'ps': they are read
# silently and passed to the AWS CLI and curl through stdin.
set -euo pipefail
export AWS_PROFILE="${AWS_PROFILE:-study}"
export AWS_REGION="${AWS_REGION:-us-east-1}"

TELEGRAM=/devops-platform/telegram-bot-token
GRAFANA=/devops-platform/grafana-admin-password
ROTATE="${1:-}"

exists() { aws ssm get-parameters --names "$1" --query 'length(Parameters)' --output text | grep -qx 1; }

put() { # name value overwrite(true|false)
  # The JSON goes through a private temp file (dir 700, file 600, deleted right after):
  # the AWS CLI cannot read a pipe via file:///dev/stdin everywhere (e.g. WSL), and
  # passing the value as an argument would expose it in 'ps'.
  local dir
  dir=$(mktemp -d); chmod 700 "$dir"
  trap 'rm -rf "$dir"' RETURN
  (umask 077; jq -n --arg n "$1" --arg v "$2" --argjson o "$3" \
    '{Name: $n, Value: $v, Type: "SecureString", Overwrite: $o}' > "$dir/param.json")
  aws ssm put-parameter --cli-input-json "file://$dir/param.json" --query Version --output text >/dev/null
}

ask_telegram_token() {
  local tg bot
  for _ in 1 2 3; do
    read -rsp "Telegram bot token (from @BotFather): " tg; echo >&2
    if [[ ! "$tg" =~ ^[0-9]{6,12}:[A-Za-z0-9_-]{35}$ ]]; then
      echo "  ✗ not a bot token (length ${#tg}, expected ~46). Paste it once, then Enter." >&2; continue
    fi
    bot=$(curl -fsS --max-time 10 -K - <<< "url = \"https://api.telegram.org/bot${tg}/getMe\"" 2>/dev/null \
      | jq -r 'select(.ok) | .result.username' 2>/dev/null || true)
    if [ -n "$bot" ]; then echo "  ✓ token belongs to @${bot}" >&2; printf '%s' "$tg"; return 0; fi
    echo "  ✗ Telegram rejected this token" >&2
  done
  return 1
}

if ! exists "$TELEGRAM" || [ "$ROTATE" = "--rotate-telegram" ]; then
  overwrite=false; exists "$TELEGRAM" && overwrite=true
  token=$(ask_telegram_token) || { echo "No valid token after 3 attempts. Aborted." >&2; exit 1; }
  put "$TELEGRAM" "$token" "$overwrite"; unset token
  echo "✓ $TELEGRAM stored"
else
  echo "· $TELEGRAM exists (use --rotate-telegram to replace)"
fi

if ! exists "$GRAFANA" || [ "$ROTATE" = "--rotate-grafana" ]; then
  overwrite=false; exists "$GRAFANA" && overwrite=true
  put "$GRAFANA" "$(openssl rand -base64 24)" "$overwrite"
  echo "✓ $GRAFANA stored (random; read it with: aws ssm get-parameter --name $GRAFANA --with-decryption --query Parameter.Value --output text)"
else
  echo "· $GRAFANA exists (use --rotate-grafana to replace)"
fi
