# Cluster services authenticate to AWS through EKS Pod Identity: a role per
# service account, trusted by the EKS Pod Identity service principal. Auto Mode
# clusters run the Pod Identity agent as part of the AWS-managed node software,
# so no add-on is installed for it here.

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

data "aws_iam_policy_document" "pod_identity_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

# ---------------------------------------------------------------------------
# Fluent Bit -> CloudWatch Logs
# ---------------------------------------------------------------------------

resource "aws_iam_role" "fluent_bit" {
  name               = "${var.cluster_name}-fluent-bit"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json
  tags               = var.tags
}

data "aws_iam_policy_document" "fluent_bit" {
  statement {
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams",
      "logs:DescribeLogGroups",
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:logs:${var.region}:${data.aws_caller_identity.current.account_id}:log-group:${var.log_group_name}",
      "arn:${data.aws_partition.current.partition}:logs:${var.region}:${data.aws_caller_identity.current.account_id}:log-group:${var.log_group_name}:*",
    ]
  }
}

resource "aws_iam_role_policy" "fluent_bit" {
  name   = "cloudwatch-logs"
  role   = aws_iam_role.fluent_bit.id
  policy = data.aws_iam_policy_document.fluent_bit.json
}

resource "aws_eks_pod_identity_association" "fluent_bit" {
  cluster_name    = module.eks.cluster_name
  namespace       = "kube-system"
  service_account = "aws-for-fluent-bit"
  role_arn        = aws_iam_role.fluent_bit.arn
  tags            = var.tags
}

# ---------------------------------------------------------------------------
# Container Insights agent
# ---------------------------------------------------------------------------

resource "aws_iam_role" "cloudwatch_observability" {
  count = var.enable_container_insights ? 1 : 0

  name               = "${var.cluster_name}-cloudwatch-agent"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "cloudwatch_observability" {
  count = var.enable_container_insights ? 1 : 0

  role       = aws_iam_role.cloudwatch_observability[0].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/CloudWatchAgentServerPolicy"
}

# ---------------------------------------------------------------------------
# ExternalDNS -> Route53
# ---------------------------------------------------------------------------

resource "aws_iam_role" "external_dns" {
  count = var.enable_external_dns ? 1 : 0

  name               = "${var.cluster_name}-external-dns"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json
  tags               = var.tags
}

data "aws_iam_policy_document" "external_dns" {
  count = var.enable_external_dns ? 1 : 0

  # scoped to the one hosted zone this cluster is allowed to publish into
  statement {
    effect    = "Allow"
    actions   = ["route53:ChangeResourceRecordSets"]
    resources = ["arn:${data.aws_partition.current.partition}:route53:::hostedzone/${var.external_dns_zone_id}"]
  }

  statement {
    effect = "Allow"
    actions = [
      "route53:ListHostedZones",
      "route53:ListResourceRecordSets",
      "route53:ListTagsForResource",
    ]
    resources = ["*"]
  }

  # Records pointing at systems outside this cluster — the legacy `root` and
  # `asap` instances, which live in another account while their names live in
  # this zone. A change batch touching any of them is refused outright, so a
  # misconfigured chart or a hand-edited ExternalDNS deployment cannot take
  # down an instance this cluster does not even run.
  dynamic "statement" {
    for_each = length(var.external_dns_protected_record_names) > 0 ? [1] : []

    content {
      sid       = "ProtectLegacyRecords"
      effect    = "Deny"
      actions   = ["route53:ChangeResourceRecordSets"]
      resources = ["*"]

      condition {
        test     = "ForAnyValue:StringEquals"
        variable = "route53:ChangeResourceRecordSetsNormalizedRecordNames"
        values   = [for name in var.external_dns_protected_record_names : lower(name)]
      }
    }
  }
}

resource "aws_iam_role_policy" "external_dns" {
  count = var.enable_external_dns ? 1 : 0

  name   = "route53"
  role   = aws_iam_role.external_dns[0].id
  policy = data.aws_iam_policy_document.external_dns[0].json
}

resource "aws_eks_pod_identity_association" "external_dns" {
  count = var.enable_external_dns ? 1 : 0

  cluster_name    = module.eks.cluster_name
  namespace       = "kube-system"
  service_account = "external-dns"
  role_arn        = aws_iam_role.external_dns[0].arn
  tags            = var.tags
}

# ---------------------------------------------------------------------------
# External Secrets Operator -> Secrets Manager
# ---------------------------------------------------------------------------

resource "aws_iam_role" "external_secrets" {
  count = var.enable_external_secrets ? 1 : 0

  name               = "${var.cluster_name}-external-secrets"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json
  tags               = var.tags
}

data "aws_iam_policy_document" "external_secrets" {
  count = var.enable_external_secrets ? 1 : 0

  statement {
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:secretsmanager:${var.region}:${data.aws_caller_identity.current.account_id}:secret:${var.external_secrets_path_prefix}",
    ]
  }

  statement {
    effect    = "Allow"
    actions   = ["secretsmanager:ListSecrets"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "external_secrets" {
  count = var.enable_external_secrets ? 1 : 0

  name   = "secrets-manager"
  role   = aws_iam_role.external_secrets[0].id
  policy = data.aws_iam_policy_document.external_secrets[0].json
}

resource "aws_eks_pod_identity_association" "external_secrets" {
  count = var.enable_external_secrets ? 1 : 0

  cluster_name    = module.eks.cluster_name
  namespace       = "external-secrets"
  service_account = "external-secrets"
  role_arn        = aws_iam_role.external_secrets[0].arn
  tags            = var.tags
}
