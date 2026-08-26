# Durable, cluster-independent resources.
#
# Two properties put something here rather than in `prod/` or `test/`: it must
# survive `tofu destroy` of the test stack, and it does not need a cluster to
# exist. That is the OIDC provider, the three deployer roles, the test cluster's
# log group, and the PR scratch bucket — the credentials needed to bring the
# test cluster back, and the evidence from the run that failed.
#
# These lived in `prod/` originally, for the first reason. The second is what
# separates them: applying `prod/` builds the production cluster, so CD could
# not authenticate to AWS until production existed, while the whole point of the
# test cluster is that it is exercised long before that. Apply order is
# bootstrap -> identity -> test -> prod.
#
# Nothing here is created or destroyed by CD, and nothing here references a
# cluster.

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  test_scratch_bucket_name = coalesce(var.test_scratch_bucket_name, "alchemiscale-test-scratch-${data.aws_caller_identity.current.account_id}")

  # Role names as constants rather than as references to the roles themselves.
  # The test-infra boundary names both, and the boundary is attached to
  # `test_infra` — referring to the resource would be a dependency cycle.
  test_infra_role_name   = "alchemiscale-test-infra"
  test_scratch_role_name = "alchemiscale-test-scratch"

  protected_bucket_names = coalesce(var.protected_bucket_names, ["alchemiscale-backups-${data.aws_caller_identity.current.account_id}"])
  protected_bucket_arns = flatten([
    for name in local.protected_bucket_names : [
      "arn:${data.aws_partition.current.partition}:s3:::${name}",
      "arn:${data.aws_partition.current.partition}:s3:::${name}/*",
    ]
  ])
}
