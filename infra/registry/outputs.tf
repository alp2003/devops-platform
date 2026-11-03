output "repository_url" {
  value = aws_ecr_repository.web.repository_url
}

output "release_role_arn" {
  value = aws_iam_role.release.arn
}
