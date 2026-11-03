locals {
  github_owner    = "alp2003"
  github_owner_id = "18375105"
  github_repo     = "devops-platform"
  github_repo_id  = "1438196115"

  # GitHub's immutable subject format (owner and repo IDs) prevents "repo-jacking":
  # a deleted and re-created repo with the same name gets a NEW ID and can't assume this role.
  github_subject = "repo:${local.github_owner}@${local.github_owner_id}/${local.github_repo}@${local.github_repo_id}"
}

# ---------------------------------------------------------------- registry
resource "aws_ecr_repository" "web" {
  name                 = "devops-platform/web"
  image_tag_mutability = "IMMUTABLE" # a pushed tag can never point to different bytes

  image_scanning_configuration {
    scan_on_push = true # basic scan of every pushed image (free)
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

# ---------------------------------------------------------------- who can push
# The OIDC provider already exists in this account (created in Lesson 9): read it, don't recreate it.
data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

data "aws_iam_policy_document" "trust" {
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
    # Only workflows triggered by a v* tag in THIS repo. Not branches, not PRs, not forks.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["${local.github_subject}:ref:refs/tags/v*"]
    }
  }
}

resource "aws_iam_role" "release" {
  name                 = "github-release-devops-platform"
  assume_role_policy   = data.aws_iam_policy_document.trust.json
  max_session_duration = 3600
}

# ---------------------------------------------------------------- what it can do
data "aws_iam_policy_document" "push" {
  statement {
    sid       = "EcrLogin"
    actions   = ["ecr:GetAuthorizationToken"] # can't be scoped to a repo (AWS design)
    resources = ["*"]
  }
  statement {
    sid = "PushAndReadThisRepoOnly"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:CompleteLayerUpload",
      "ecr:DescribeImages",
      "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload",
      "ecr:ListImages",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
    ]
    resources = [aws_ecr_repository.web.arn]
    # Deliberately NO ecr:BatchDeleteImage: CI can add images, never remove them.
  }
}

resource "aws_iam_role_policy" "push" {
  name   = "ecr-push-web"
  role   = aws_iam_role.release.id
  policy = data.aws_iam_policy_document.push.json
}
