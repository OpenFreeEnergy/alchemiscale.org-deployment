# GitHub OIDC federation. No long-lived AWS keys exist in repository secrets;
# workflows exchange their run's OIDC token for one of three roles, each with a
# deliberately different reach:
#
#   alchemiscale-deploy-release  prod cluster only, gated behind the
#                                production-* GitHub Environments
#   alchemiscale-deploy-pr       test cluster only — no access entry on prod
#                                exists for it at all
#   alchemiscale-test-infra      tofu apply/destroy of the test stack, fenced in
#                                by a permissions boundary
#
# All three are declared here, in the layer that is never destroyed and needs no
# cluster, precisely so that `tofu destroy` of the test stack cannot remove the
# credentials needed to bring it back — and so that CD has an identity to
# authenticate with before the production cluster is built.

locals {
  oidc_provider_url = "token.actions.githubusercontent.com"
  oidc_provider_arn = var.create_github_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : data.aws_iam_openid_connect_provider.github[0].arn
}

resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_github_oidc_provider ? 1 : 0

  url             = "https://${local.oidc_provider_url}"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

data "aws_iam_openid_connect_provider" "github" {
  count = var.create_github_oidc_provider ? 0 : 1

  url = "https://${local.oidc_provider_url}"
}

# ---------------------------------------------------------------------------
# release deployer
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "deploy_release_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider_url}:aud"
      values   = ["sts.amazonaws.com"]
    }

    # only runs bound to a production-* GitHub Environment, which carries
    # required reviewers — the manual gate before a production rollout
    condition {
      test     = "StringLike"
      variable = "${local.oidc_provider_url}:sub"
      values   = ["repo:${var.github_repository}:environment:production-*"]
    }
  }
}

resource "aws_iam_role" "deploy_release" {
  name                 = "alchemiscale-deploy-release"
  description          = "Release CD: helm upgrade against the production cluster"
  assume_role_policy   = data.aws_iam_policy_document.deploy_release_trust.json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "deploy_release" {
  statement {
    sid       = "DescribeProdCluster"
    effect    = "Allow"
    actions   = ["eks:DescribeCluster", "eks:ListClusters"]
    resources = ["*"]

    condition {
      test     = "StringEqualsIfExists"
      variable = "aws:ResourceTag/cluster"
      values   = ["prod"]
    }
  }

  # pre-upgrade snapshot of the neo4j volume (see release-deploy.yml)
  statement {
    sid    = "PreUpgradeSnapshot"
    effect = "Allow"
    actions = [
      "ec2:DescribeVolumes",
      "ec2:DescribeSnapshots",
      "ec2:CreateSnapshot",
      "ec2:CreateTags",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "deploy_release" {
  name   = "deploy-release"
  role   = aws_iam_role.deploy_release.id
  policy = data.aws_iam_policy_document.deploy_release.json
}

# ---------------------------------------------------------------------------
# PR deployer
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "deploy_pr_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider_url}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "${local.oidc_provider_url}:sub"
      values = [
        "repo:${var.github_repository}:pull_request",
        "repo:${var.github_repository}:ref:refs/heads/main",
      ]
    }
  }
}

resource "aws_iam_role" "deploy_pr" {
  name               = "alchemiscale-deploy-pr"
  description        = "PR CD: helm install/uninstall against the test cluster"
  assume_role_policy = data.aws_iam_policy_document.deploy_pr_trust.json
}

data "aws_iam_policy_document" "deploy_pr" {
  statement {
    sid       = "DescribeTestCluster"
    effect    = "Allow"
    actions   = ["eks:DescribeCluster", "eks:ListClusters"]
    resources = ["*"]

    condition {
      test     = "StringEqualsIfExists"
      variable = "aws:ResourceTag/cluster"
      values   = ["test"]
    }
  }

  # per-PR scratch object store, and the teardown that removes it
  statement {
    sid    = "ScratchObjects"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    resources = ["${aws_s3_bucket.test_scratch.arn}/pr-*"]
  }

  statement {
    sid       = "ScratchList"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.test_scratch.arn]
  }

  # PR namespaces are created at deploy time, so their Pod Identity association
  # cannot be declared in advance the way production's is
  statement {
    sid    = "PRNamespacePodIdentity"
    effect = "Allow"
    actions = [
      "eks:CreatePodIdentityAssociation",
      "eks:DeletePodIdentityAssociation",
      "eks:ListPodIdentityAssociations",
      "eks:DescribePodIdentityAssociation",
    ]
    resources = ["*"]

    condition {
      test     = "StringEqualsIfExists"
      variable = "aws:ResourceTag/cluster"
      values   = ["test"]
    }
  }

  statement {
    sid       = "PassScratchRole"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = [aws_iam_role.test_scratch.arn]
  }
}

resource "aws_iam_role_policy" "deploy_pr" {
  name   = "deploy-pr"
  role   = aws_iam_role.deploy_pr.id
  policy = data.aws_iam_policy_document.deploy_pr.json
}

# ---------------------------------------------------------------------------
# test cluster infrastructure lifecycle
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "test_infra_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider_url}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "${local.oidc_provider_url}:sub"
      values   = ["repo:${var.github_repository}:*"]
    }

    # This role can only be assumed from the lifecycle workflow file itself.
    # Note the residual exposure: `pr-deploy.yml` calls that workflow through
    # `workflow_call`, and a same-repo pull request can edit the called file, so
    # the effective trust boundary is "anyone who can open a branch PR" — repo
    # collaborators. Fork PRs never reach this path (the deploy jobs are gated
    # on same-repo head), and the permissions boundary below is what keeps a
    # mistake here away from production. Tighten to `:ref:refs/heads/main` and
    # switch pr-deploy to `gh workflow run` if that trade stops being acceptable.
    condition {
      test     = "StringLike"
      variable = "${local.oidc_provider_url}:job_workflow_ref"
      values   = ["${var.github_repository}/.github/workflows/test-cluster-lifecycle.yml@*"]
    }
  }
}

resource "aws_iam_role" "test_infra" {
  name                 = local.test_infra_role_name
  description          = "tofu apply/destroy of the ephemeral test cluster"
  assume_role_policy   = data.aws_iam_policy_document.test_infra_trust.json
  permissions_boundary = aws_iam_policy.test_infra_boundary.arn
  max_session_duration = 3600
}

# Standing up an EKS cluster genuinely requires broad EC2/EKS/IAM/VPC rights.
# The boundary is what makes that survivable: nothing tagged `cluster=prod` is
# reachable, the backups bucket and the durable roles are denied by name, and
# IAM writes are confined to the test cluster's own role names.
data "aws_iam_policy_document" "test_infra_boundary" {
  statement {
    sid    = "InfrastructureManagement"
    effect = "Allow"
    actions = [
      "ec2:*",
      "eks:*",
      "iam:*",
      "logs:*",
      "elasticloadbalancing:*",
      "autoscaling:*",
      "kms:Decrypt",
      "kms:GenerateDataKey",
      "kms:DescribeKey",
      "sts:*",
      "tag:GetResources",
    ]
    resources = ["*"]
  }

  # The only S3 this role needs is its own OpenTofu state: the test stack
  # creates no buckets. Scoping the grant here, rather than allowing `s3:*` and
  # denying the buckets we remember to name, is what keeps the neo4j backups,
  # the per-deployment object stores, and the other layers' state out of reach —
  # including buckets that do not exist yet.
  #
  # This is also why KMS stays broad: the role legitimately creates and manages
  # the EKS cluster's own encryption key, and state is encrypted with the same
  # key this role must use for `test/`. There is no line to draw in KMS, so the
  # line is drawn in S3.
  statement {
    sid    = "TestStateObjects"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    resources = ["arn:${data.aws_partition.current.partition}:s3:::${local.state_bucket_name}/test/*"]
  }

  statement {
    sid       = "TestStateBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = ["arn:${data.aws_partition.current.partition}:s3:::${local.state_bucket_name}"]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["test/*"]
    }
  }

  statement {
    sid       = "NeverTouchProduction"
    effect    = "Deny"
    actions   = ["*"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/cluster"
      values   = ["prod"]
    }
  }

  statement {
    sid    = "ConfineIAMWrites"
    effect = "Deny"
    actions = [
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:UpdateAssumeRolePolicy",
      "iam:CreateUser",
      "iam:CreateAccessKey",
      "iam:DeleteUserPolicy",
      "iam:PutUserPolicy",
    ]
    not_resources = [
      "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role/${var.test_cluster_name}*",
      "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role/aws-service-role/*",
    ]
  }

  statement {
    sid       = "NeverEscapeTheBoundary"
    effect    = "Deny"
    actions   = ["iam:DeleteRolePermissionsBoundary", "iam:PutRolePermissionsBoundary"]
    resources = ["*"]
  }

  # `ConfineIAMWrites` allows role names beginning with `alchemiscale-test`,
  # which is also the prefix of the two durable roles declared in this module —
  # so on its own it lets the lifecycle role delete itself, or the scratch role
  # every PR environment depends on. The cluster's own roles
  # (`alchemiscale-test-fluent-bit` and friends) are created and destroyed
  # routinely and stay reachable; these two never are.
  statement {
    sid    = "NeverTouchDurableRoles"
    effect = "Deny"
    actions = [
      "iam:DeleteRole",
      "iam:UpdateAssumeRolePolicy",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role/${local.test_infra_role_name}",
      "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role/${local.test_scratch_role_name}",
    ]
  }

  # The backups bucket holds the neo4j dumps and is declared in `prod/`, whose
  # state this module deliberately cannot read — hence a name rather than a
  # reference. Tagging is not an alternative: S3 evaluates `aws:ResourceTag` for
  # only a handful of actions, so the `cluster=prod` deny above, which covers
  # production everywhere else, silently fails to cover a bucket. Naming it is
  # the only form of the deny that actually denies.
  #
  # The default is derived exactly as `prod/` derives the bucket name, so the
}

resource "aws_iam_policy" "test_infra_boundary" {
  name        = "alchemiscale-test-infra-boundary"
  description = "Permissions boundary for the test cluster lifecycle role"
  policy      = data.aws_iam_policy_document.test_infra_boundary.json
}

resource "aws_iam_role_policy_attachment" "test_infra" {
  role = aws_iam_role.test_infra.name
  # the boundary above, not this attachment, is what constrains the role
  policy_arn = aws_iam_policy.test_infra_boundary.arn
}
