# External Secrets Operator reads the platform's secrets from SSM Parameter Store
# (SecureString, path /devops-platform/*) and writes them as Kubernetes Secrets.
# Read-only, one path, this cluster only. Values are created once by
# scripts/secrets-init.sh and never pass through Terraform (so never into state).

locals {
  secrets_path = "devops-platform"
}

data "aws_iam_policy_document" "eso_read_parameters" {
  statement {
    sid       = "ReadPlatformParameters"
    actions   = ["ssm:GetParameter", "ssm:GetParameters"]
    resources = ["arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter/${local.secrets_path}/*"]
    # SecureStrings use the AWS-managed key aws/ssm: its key policy already allows
    # decryption through SSM for principals in this account, so no kms:Decrypt here.
  }
}

resource "aws_iam_role" "external_secrets" {
  name               = "${var.cluster_name}-external-secrets"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json
}

resource "aws_iam_role_policy" "external_secrets" {
  name   = "read-${local.secrets_path}-parameters"
  role   = aws_iam_role.external_secrets.id
  policy = data.aws_iam_policy_document.eso_read_parameters.json
}

resource "aws_eks_pod_identity_association" "external_secrets" {
  cluster_name    = module.eks.cluster_name
  namespace       = "external-secrets"
  service_account = "external-secrets" # the controller; webhook and cert-controller get no AWS access
  role_arn        = aws_iam_role.external_secrets.arn
}
