# Roles that let GitHub Actions run Terraform, so infrastructure changes go through
# PRs like everything else instead of being applied from a laptop.
#
#   plan  : PRs and the nightly drift check. Read-only, secrets explicitly denied:
#           a PR author controls the workflow file on their branch, so assume any
#           code can run with this role.
#   apply : only jobs in the GitHub environment "infra", which is limited to main
#           and needs a manual approval. Broad rights, because Terraform manages IAM.
#
# Chicken and egg: this file is applied once from the admin machine; afterwards CI
# manages it like any other change.

locals {
  github_subject = "repo:alp2003@18375105/devops-platform@1438196115" # immutable form (owner/repo IDs)
}

data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

data "aws_iam_policy_document" "tf_plan_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    # PRs in this repo (forks get no OIDC token) and runs on main (drift check)
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["${local.github_subject}:pull_request", "${local.github_subject}:ref:refs/heads/main"]
    }
  }
}

resource "aws_iam_role" "tf_plan" {
  name                 = "github-terraform-plan-devops-platform"
  assume_role_policy   = data.aws_iam_policy_document.tf_plan_trust.json
  max_session_duration = 3600
}

resource "aws_iam_role_policy_attachment" "tf_plan_read" {
  role       = aws_iam_role.tf_plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# ReadOnlyAccess can read secret VALUES. Plans never need them: deny explicitly.
# SSM is denied only for THIS account's parameters: AWS's public parameters
# (arn:aws:ssm:<region>::parameter/aws/service/..., e.g. the EKS AMI the node group
# looks up) have no account ID in their ARN and must stay readable.
data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "tf_plan_deny_secrets" {
  statement {
    sid    = "NoOwnParameterValues"
    effect = "Deny"
    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:GetParametersByPath",
      "ssm:GetParameterHistory",
    ]
    resources = ["arn:aws:ssm:*:${data.aws_caller_identity.current.account_id}:parameter/*"]
  }
  statement {
    sid       = "NoSecretValues"
    effect    = "Deny"
    actions   = ["secretsmanager:GetSecretValue", "kms:Decrypt"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "tf_plan_deny_secrets" {
  name   = "deny-secret-values"
  role   = aws_iam_role.tf_plan.id
  policy = data.aws_iam_policy_document.tf_plan_deny_secrets.json
}

data "aws_iam_policy_document" "tf_apply_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    # Only jobs that declare "environment: infra" (main only, approval required)
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["${local.github_subject}:environment:infra"]
    }
  }
}

resource "aws_iam_role" "tf_apply" {
  name                 = "github-terraform-apply-devops-platform"
  assume_role_policy   = data.aws_iam_policy_document.tf_apply_trust.json
  max_session_duration = 3600
}

resource "aws_iam_role_policy_attachment" "tf_apply_admin" {
  role       = aws_iam_role.tf_apply.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess" # Terraform manages IAM itself
}

output "tf_plan_role_arn" {
  value = aws_iam_role.tf_plan.arn
}

output "tf_apply_role_arn" {
  value = aws_iam_role.tf_apply.arn
}
