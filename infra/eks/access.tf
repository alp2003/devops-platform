# Who can do what in the cluster.
#
# Three IAM roles, each mapped to Kubernetes permissions with an EKS access entry
# (no aws-auth ConfigMap). People assume a role, they don't get access as themselves:
#
#   role                       Kubernetes access
#   platform-admin             cluster-admin everywhere (break-glass, platform team)
#   platform-developer         edit in web-dev, read-only in web-prod, nothing else
#   platform-viewer            read-only everywhere, secrets excluded (support, auditors)
#
# Prod changes go through Git (promotion PRs + ArgoCD), so nobody but the admin role
# can change prod by hand. Even an admin can't run an unsigned image: Kyverno
# checks every pod, whoever creates it.
#
# The cluster creator (your own identity from AWS_PROFILE) also keeps admin access via
# enable_cluster_creator_admin_permissions, so up.sh and ArgoCD bootstrap keep working.

locals {
  access_roles = {
    admin     = "Cluster admin (break-glass)"
    developer = "Edit web-dev, read web-prod"
    viewer    = "Read-only, no secrets"
  }

  eks_access_policy = "arn:aws:eks::aws:cluster-access-policy"
}

# Trust: principals in this account only, and only those whose own IAM policy allows
# sts:AssumeRole on the role. Production: trust specific SSO permission sets and
# require MFA (aws:MultiFactorAuthPresent).
data "aws_iam_policy_document" "access_trust" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }
}

resource "aws_iam_role" "access" {
  for_each = local.access_roles

  name                 = "${var.cluster_name}-${each.key}"
  description          = each.value
  assume_role_policy   = data.aws_iam_policy_document.access_trust.json
  max_session_duration = 3600
}

# The only AWS permission these roles need: read the cluster endpoint for kubeconfig.
# Everything inside the cluster is granted by the access entries below.
data "aws_iam_policy_document" "describe_cluster" {
  statement {
    actions   = ["eks:DescribeCluster"]
    resources = [module.eks.cluster_arn]
  }
}

resource "aws_iam_role_policy" "describe_cluster" {
  for_each = aws_iam_role.access

  name   = "eks-describe-cluster"
  role   = each.value.id
  policy = data.aws_iam_policy_document.describe_cluster.json
}

output "access_role_arns" {
  description = "IAM roles for cluster access; see scripts/access-check.sh"
  value       = { for k, r in aws_iam_role.access : k => r.arn }
}
