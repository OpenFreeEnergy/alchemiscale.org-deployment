# Container log groups.
#
# The production group is the same `alchemiscale` group the EC2 hosts write to
# through the compose `awslogs` driver, so pre- and post-migration logs stay
# side by side. It almost certainly already exists — import it rather than
# letting the first apply fail:
#
#   tofu import aws_cloudwatch_log_group.prod alchemiscale

resource "aws_cloudwatch_log_group" "prod" {
  name              = var.log_group_name
  retention_in_days = var.log_retention_days

  lifecycle {
    prevent_destroy = true
  }
}

# The test cluster's log group lives here, in the layer the reaper never
# destroys: an investigation into why a PR environment failed should not end
# because the cluster was spun down while it was under way.
resource "aws_cloudwatch_log_group" "test" {
  name              = var.test_cluster_name
  retention_in_days = var.test_log_retention_days
}

# Scratch object store for PR environments, one `pr-<n>/` prefix each. Teardown
# deletes the prefix; the lifecycle rule is the backstop for the teardown that
# never ran.
resource "aws_s3_bucket" "test_scratch" {
  bucket = local.test_scratch_bucket_name

  tags = {
    cluster = "test"
  }
}

resource "aws_s3_bucket_public_access_block" "test_scratch" {
  bucket = aws_s3_bucket.test_scratch.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "test_scratch" {
  bucket = aws_s3_bucket.test_scratch.id

  rule {
    id     = "expire-pr-scratch"
    status = "Enabled"

    filter {
      prefix = "pr-"
    }

    expiration {
      days = var.test_scratch_expire_after_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

# Application identity for PR namespaces: one role, scoped to the scratch
# bucket, associated with every `*-pr-*` namespace by the test root module.
resource "aws_iam_role" "test_scratch" {
  name               = "alchemiscale-test-scratch"
  description        = "Application identity for PR environments on the test cluster"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json

  tags = {
    cluster = "test"
  }
}

data "aws_iam_policy_document" "test_scratch" {
  statement {
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.test_scratch.arn}/pr-*"]
  }

  statement {
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.test_scratch.arn]
  }
}

resource "aws_iam_role_policy" "test_scratch" {
  name   = "scratch-object-store"
  role   = aws_iam_role.test_scratch.id
  policy = data.aws_iam_policy_document.test_scratch.json
}
