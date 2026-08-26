variable "region" {
  description = "AWS region hosting the production cluster."
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "Name of the production EKS cluster."
  type        = string
  default     = "alchemiscale-prod"
}

variable "kubernetes_version" {
  description = "Kubernetes version for the production control plane. Keep this inside the EKS standard support window — extended support costs $0.60/hr instead of $0.10/hr."
  type        = string
  default     = "1.36"
}

variable "vpc_cidr" {
  description = "CIDR for the production VPC."
  type        = string
  default     = "10.10.0.0/16"
}

variable "hosted_zone_name" {
  description = "Route53 public hosted zone that already exists in this account and delegates the deployment hostnames."
  type        = string
  default     = "alchemiscale.org"
}

variable "deployments" {
  description = <<-EOT
    The named alchemiscale instances this cluster hosts. One entry produces a
    namespace, an ACM certificate, Secrets Manager entries, a Pod Identity role
    scoped to that deployment's S3 prefix, health checks, alarms, and a
    dashboard — adding an instance is a map entry plus a values file, which is
    the whole reason this design pays off past three deployments.
  EOT
  type = map(object({
    # subdomain of the hosted zone this instance answers on; hostnames are
    # api.<domain> and compute.<domain>
    domain = string
    # object store the API services read and write results to
    s3_bucket = string
    s3_prefix = string
    # Whether api.<domain> is answering yet. Outside-in health checks and their
    # alarms are only created for live endpoints — a health check against a
    # hostname that does not resolve alarms immediately and pages about nothing.
    # Flip to true as each instance goes live. The check follows the
    # user-facing endpoint, not the backend behind it.
    live = optional(bool, false)
  }))

  default = {
    omsf = {
      domain    = "omsf.alchemiscale.org"
      s3_bucket = "alchemiscale-omsf"
      s3_prefix = "object-store"
    }
    openadmet = {
      domain    = "openadmet.alchemiscale.org"
      s3_bucket = "alchemiscale-openadmet"
      s3_prefix = "object-store"
    }
  }
}

variable "builtin_node_pools" {
  description = "EKS Auto Mode built-in node pools, used instead of the module's custom NodeClass/NodePool. Production is on-demand either way, so the built-ins cost nothing here. See docs/infrastructure.md#node-pools."
  type        = list(string)
  default     = ["general-purpose"]
}

variable "admin_principal_arns" {
  description = "IAM principals (operators) granted cluster-admin on the production cluster. Identity administration and the neo4j dump/restore scripts need this."
  type        = list(string)
  default     = []
}

variable "deploy_release_role_name" {
  description = <<-EOT
    Name of the release deployer role, declared in the identity root module and
    granted an access entry here. Set to "" to apply this cluster before that
    module exists — release CD then has no way into the cluster until it does.
  EOT
  type        = string
  default     = "alchemiscale-deploy-release"
}

variable "log_group_name" {
  description = "CloudWatch log group container logs are shipped to. Matches the group the EC2 hosts already write to, so historical and post-migration logs live together."
  type        = string
  default     = "alchemiscale"
}

variable "log_retention_days" {
  description = "Retention on the production log group."
  type        = number
  default     = 90
}

variable "legacy_dns_names" {
  description = <<-EOT
    Hostnames that still point at instances in the legacy account, and which
    this cluster must never touch.

    Since the hosted zone moved into this account, these records live in a zone
    the cluster's ExternalDNS can write to — so they are protected two ways:
    excluded from ExternalDNS's own domain handling, and explicitly denied in
    its IAM policy, which holds regardless of chart or controller configuration.

    `api.alchemiscale.org`/`compute.alchemiscale.org` stay for the duration of
    the root -> omsf parallel run. The `asap` entries stay indefinitely: that
    instance is not managed by this infrastructure and keeps running on its own
    host, so the cluster must never claim its records.
  EOT
  type        = list(string)
  default = [
    "api.alchemiscale.org",
    "compute.alchemiscale.org",
    "api.asap.alchemiscale.org",
    "compute.asap.alchemiscale.org",
  ]
}

variable "legacy_dns_editor_account_ids" {
  description = <<-EOT
    AWS accounts allowed to assume a role in this account that can edit the
    legacy records in `legacy_dns_names` — and nothing else in the zone.

    The hosted zone now lives here, but the `root` and `asap` instances do not.
    Without this, whoever operates those hosts cannot repoint their own records
    (after an instance replacement, say) without going through an OMSF-account
    administrator. Empty disables the role.
  EOT
  type        = list(string)
  default     = []
}

variable "backups_bucket_name" {
  description = "Bucket holding neo4j logical dumps. Deliberately separate from the object-store buckets, which this infrastructure otherwise never touches."
  type        = string
  default     = null
}

variable "backup_glacier_after_days" {
  description = "Days before a dump transitions to Glacier Instant Retrieval."
  type        = number
  default     = 30
}

variable "backup_expire_after_days" {
  description = "Days before a dump is deleted."
  type        = number
  default     = 180
}

variable "snapshot_retention_count" {
  description = "Number of daily EBS snapshots of the neo4j volumes to retain (DLM)."
  type        = number
  default     = 14
}

variable "alert_emails" {
  description = "Addresses subscribed to the alarm SNS topic. Each requires a one-time confirmation click."
  type        = list(string)
  default     = []
}

variable "enable_alb_alarms" {
  description = <<-EOT
    Create ALB 5xx / unhealthy-target alarms. The ALB is provisioned by EKS Auto
    Mode from the chart's Ingress, so it does not exist on the first apply —
    turn this on once at least one deployment is serving.
  EOT
  type        = bool
  default     = false
}
