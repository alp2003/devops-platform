# Kyverno verifies the cosign signatures stored next to our images in ECR, so its
# controllers need read access to that one repository. EKS Pod Identity gives them
# short-lived AWS credentials: no static keys, and no borrowing the node's role.

data "aws_ecr_repository" "web" {
  name = "devops-platform/web" # owned by infra/registry (persistent stack)
}

data "aws_iam_policy_document" "kyverno_trust" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
    # Only Pod Identity calls from THIS account and THIS cluster
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [module.eks.cluster_arn]
    }
  }
}

data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "kyverno_ecr_read" {
  statement {
    sid       = "EcrLogin"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"] # this API has no resource-level permissions
  }
  statement {
    sid = "ReadWebRepository"
    actions = [
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchCheckLayerAvailability",
      "ecr:DescribeImages",
      "ecr:ListImages",
    ]
    resources = [data.aws_ecr_repository.web.arn]
  }
}

resource "aws_iam_role" "kyverno" {
  name               = "${var.cluster_name}-kyverno-ecr-read"
  assume_role_policy = data.aws_iam_policy_document.kyverno_trust.json
}

resource "aws_iam_role_policy" "kyverno_ecr_read" {
  name   = "ecr-read-web"
  role   = aws_iam_role.kyverno.id
  policy = data.aws_iam_policy_document.kyverno_ecr_read.json
}

# Admission verifies at pod creation; the reports controller re-checks in the background
resource "aws_eks_pod_identity_association" "kyverno" {
  for_each = toset(["kyverno-admission-controller", "kyverno-reports-controller"])

  cluster_name    = module.eks.cluster_name
  namespace       = "kyverno"
  service_account = each.value
  role_arn        = aws_iam_role.kyverno.arn
}
