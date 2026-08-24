# Bootstrap layer: the state bucket and the KMS key that encrypts state.
#
# This is the one configuration that keeps its state locally — it has nowhere
# else to put it. Apply it once, by hand, before the `prod` or `test` root
# modules are ever initialised:
#
#   tofu -chdir=infra/opentofu/bootstrap init
#   tofu -chdir=infra/opentofu/bootstrap apply
#
# The resulting `terraform.tfstate` is deliberately gitignored: it describes two
# resources that can be trivially imported if lost.

terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.59"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      project   = "alchemiscale"
      managedby = "opentofu"
      layer     = "bootstrap"
    }
  }
}

variable "region" {
  description = "AWS region for the state bucket and KMS key."
  type        = string
  default     = "us-east-1"
}

variable "state_bucket_name" {
  description = "Name of the OpenTofu state bucket. Must be globally unique; defaults to a name derived from the account ID."
  type        = string
  default     = null
}

data "aws_caller_identity" "current" {}

locals {
  state_bucket_name = coalesce(var.state_bucket_name, "alchemiscale-tofu-state-${data.aws_caller_identity.current.account_id}")
}

# Key used by OpenTofu's client-side state encryption. State holds cluster,
# IAM, and secret-adjacent detail, so it is encrypted before it ever reaches S3
# — S3's own at-rest encryption is not the only thing standing between an
# unintended reader and the contents.
resource "aws_kms_key" "state" {
  description             = "alchemiscale OpenTofu state encryption"
  deletion_window_in_days = 30
  enable_key_rotation     = true
}

resource "aws_kms_alias" "state" {
  name          = "alias/alchemiscale-tofu-state"
  target_key_id = aws_kms_key.state.key_id
}

resource "aws_s3_bucket" "state" {
  bucket = local.state_bucket_name

  # deleting the state bucket should take deliberate effort
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

output "state_bucket" {
  description = "Pass this to `tofu init -backend-config=\"bucket=...\"` for the prod and test root modules."
  value       = aws_s3_bucket.state.id
}

output "state_kms_key_alias" {
  description = "Alias referenced by the `encryption` block in each root module."
  value       = aws_kms_alias.state.name
}
