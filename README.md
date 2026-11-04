# devops-platform

A hardened EKS platform with a signed, versioned release pipeline.
*(Full write-up: architecture, security chain and design decisions, coming in Phase 7.)*

## Operating it

| Step | Command | Notes |
|---|---|---|
| Secrets (once) | `./scripts/secrets-init.sh` | stores the Telegram bot token (validated) and a random Grafana password in SSM Parameter Store. They persist across clusters; External Secrets syncs them in. `--rotate-grafana` / `--rotate-telegram` to replace. |
| Bring up | `./scripts/up.sh` | ~20 min. Checks the SSM secrets exist first, then asks nothing. Pins the API endpoint only if one of its IPs is unreachable. |
| Wait | `watch -n 10 'kubectl get applications -n argocd'` | until every app is **Synced / Healthy** |
| Verify | `./scripts/verify.sh` | **Run it ~5 minutes after everything is Healthy.** Right after install, Helm hook jobs are still finishing and the Prometheus Operator logs webhook `bad certificate` errors until its certificate is patched in (install-time race, it stops on its own). |
| Promote | `gh workflow run promote.yaml -f version=X.Y.Z` | opens a PR copying dev's exact digest to prod |
| Roll back | `gh pr revert <promotion PR>` | merge it: ArgoCD returns prod to the previous digest |
| Tear down | `./scripts/down.sh` then `./scripts/aws-cost-check.sh` | always: the cluster costs money per hour |
