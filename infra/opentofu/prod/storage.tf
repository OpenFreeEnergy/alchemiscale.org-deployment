# ---------------------------------------------------------------------------
# backups bucket (neo4j logical dumps)
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "backups" {
  bucket = local.backups_bucket_name
}

resource "aws_s3_bucket_versioning" "backups" {
  bucket = aws_s3_bucket.backups.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "backups" {
  bucket = aws_s3_bucket.backups.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id

  rule {
    id     = "archive-then-expire"
    status = "Enabled"

    filter {}

    transition {
      days          = var.backup_glacier_after_days
      storage_class = "GLACIER_IR"
    }

    expiration {
      days = var.backup_expire_after_days
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}

# ---------------------------------------------------------------------------
# per-deployment application identity
#
# This is what removes AWS_ACCESS_KEY_ID/SECRET from the server config path: the
# API, strategist, and dump/restore pods get credentials from EKS Pod Identity,
# scoped to exactly one deployment's object-store prefix.
# ---------------------------------------------------------------------------

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

resource "aws_iam_role" "deployment" {
  for_each = var.deployments

  name               = "alchemiscale-${each.key}"
  description        = "Application identity for the ${each.key} alchemiscale deployment"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json
}

data "aws_iam_policy_document" "deployment" {
  for_each = var.deployments

  statement {
    sid       = "ListObjectStorePrefix"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = ["arn:${data.aws_partition.current.partition}:s3:::${each.value.s3_bucket}"]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["${each.value.s3_prefix}/*", each.value.s3_prefix]
    }
  }

  statement {
    sid    = "ObjectStore"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    resources = ["arn:${data.aws_partition.current.partition}:s3:::${each.value.s3_bucket}/${each.value.s3_prefix}/*"]
  }

  # neo4j dump/restore jobs stream through the backups bucket
  statement {
    sid       = "BackupsPrefix"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject"]
    resources = ["${aws_s3_bucket.backups.arn}/${each.key}/*"]
  }

  statement {
    sid       = "BackupsList"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.backups.arn]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["${each.key}/*"]
    }
  }

  # the neo4j disk-usage sidecar publishes one custom metric
  statement {
    sid       = "PublishDiskMetric"
    effect    = "Allow"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = ["alchemiscale"]
    }
  }
}

resource "aws_iam_role_policy" "deployment" {
  for_each = var.deployments

  name   = "alchemiscale-${each.key}"
  role   = aws_iam_role.deployment[each.key].id
  policy = data.aws_iam_policy_document.deployment[each.key].json
}

resource "aws_eks_pod_identity_association" "deployment" {
  for_each = var.deployments

  cluster_name = module.cluster.cluster_name
  namespace    = each.key
  # matches `serviceAccount.name` in the chart
  service_account = "alchemiscale"
  role_arn        = aws_iam_role.deployment[each.key].arn

  depends_on = [kubernetes_namespace_v1.deployment]
}

# ---------------------------------------------------------------------------
# scheduled EBS snapshots of the neo4j volumes (DLM)
#
# Crash-consistent block snapshots, entirely at the EBS layer — no CSI snapshot
# controller to install or upgrade. Portability across neo4j versions comes from
# logical dumps (scripts/neo4j-dump.sh), not from these.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "dlm_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["dlm.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "dlm" {
  name               = "alchemiscale-dlm-snapshots"
  assume_role_policy = data.aws_iam_policy_document.dlm_trust.json
}

resource "aws_iam_role_policy_attachment" "dlm" {
  role       = aws_iam_role.dlm.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWSDataLifecycleManagerServiceRole"
}

resource "aws_dlm_lifecycle_policy" "neo4j" {
  description        = "Daily snapshots of alchemiscale neo4j volumes"
  execution_role_arn = aws_iam_role.dlm.arn
  state              = "ENABLED"

  policy_details {
    resource_types = ["VOLUME"]

    # the tag comes from the StorageClass `tagSpecification_1` parameter; after
    # the first PVC is provisioned, confirm the volume actually carries it
    target_tags = {
      "alchemiscale-snapshot" = "true"
    }

    schedule {
      name = "daily"

      create_rule {
        interval      = 24
        interval_unit = "HOURS"
        times         = ["07:00"]
      }

      retain_rule {
        count = var.snapshot_retention_count
      }

      tags_to_add = {
        SnapshotCreator = "dlm"
      }

      copy_tags = true
    }
  }
}
