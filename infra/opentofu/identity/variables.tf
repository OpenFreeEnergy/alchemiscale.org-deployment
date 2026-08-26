variable "region" {
  description = "AWS region for the regional resources here (log group, scratch bucket). Must match the region both clusters run in."
  type        = string
  default     = "us-east-1"
}

variable "github_repository" {
  description = "`owner/repo` allowed to assume the deployer roles through GitHub OIDC."
  type        = string
  default     = "OpenFreeEnergy/alchemiscale.org-deployment"
}

variable "create_github_oidc_provider" {
  description = "Create the GitHub OIDC provider. Set false if the account already has one (only one per account is permitted)."
  type        = bool
  default     = true
}

variable "test_cluster_name" {
  description = "Name of the test cluster. Names its log group, and confines the test-infra role's IAM writes to role names beginning with it."
  type        = string
  default     = "alchemiscale-test"
}

variable "test_log_retention_days" {
  description = "Retention on the test cluster's log group — short, but long enough that a postmortem outlives the reaper."
  type        = number
  default     = 14
}

variable "test_scratch_bucket_name" {
  description = "Bucket PR environments use as their object store, under a `pr-<n>/` prefix per environment."
  type        = string
  default     = null
}

variable "test_scratch_expire_after_days" {
  description = "Days before PR scratch objects are expired, as a backstop for teardown that never ran."
  type        = number
  default     = 7
}

variable "protected_bucket_names" {
  description = <<-EOT
    Buckets the test-infra permissions boundary denies all S3 access to.

    `null` (the default) protects the name `prod/` gives its backups bucket, so
    the neo4j dumps are out of reach without this module reading prod's state.
    Set it explicitly if prod overrides `backups_bucket_name`; `[]` drops the
    deny entirely, which is only reasonable if no such bucket exists yet.

    Not the state bucket: the test-infra role writes the test cluster's state
    there, so it must stay reachable.
  EOT
  type        = list(string)
  default     = null
}
