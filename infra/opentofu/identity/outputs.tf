output "deploy_release_role_arn" {
  description = "Role assumed by release-deploy.yml. Set as the repository variable AWS_DEPLOY_RELEASE_ROLE."
  value       = aws_iam_role.deploy_release.arn
}

output "deploy_pr_role_arn" {
  description = "Role assumed by pr-deploy.yml / pr-teardown.yml. Set as the repository variable AWS_DEPLOY_PR_ROLE."
  value       = aws_iam_role.deploy_pr.arn
}

output "test_infra_role_arn" {
  description = "Role assumed by test-cluster-lifecycle.yml. Set as the repository variable AWS_TEST_INFRA_ROLE."
  value       = aws_iam_role.test_infra.arn
}

output "test_scratch_role_arn" {
  description = "Pod Identity role PR environments use for their scratch object store. Set as the repository variable TEST_SCRATCH_ROLE_ARN."
  value       = aws_iam_role.test_scratch.arn
}

output "test_scratch_bucket" {
  description = "Bucket PR environments write to, under `pr-<n>/`. Set as the repository variable TEST_SCRATCH_BUCKET."
  value       = aws_s3_bucket.test_scratch.id
}

output "test_log_group" {
  description = "Log group the test cluster's Fluent Bit ships to; `test/` expects it to exist under this name."
  value       = aws_cloudwatch_log_group.test.name
}
