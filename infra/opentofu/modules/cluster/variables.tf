variable "cluster_name" {
  description = "Name of the EKS cluster; also used as the VPC name prefix and as the discovery tag value for node placement."
  type        = string
}

variable "kubernetes_version" {
  description = "Kubernetes `<major>.<minor>` version for the control plane. Keep within the EKS standard support window; extended support is billed at 6x the control plane rate."
  type        = string
}

variable "region" {
  description = "AWS region to deploy into."
  type        = string
}

variable "cluster_support_type" {
  description = <<-EOT
    `STANDARD` lets AWS auto-upgrade the cluster when its version leaves the
    standard support window. `EXTENDED` keeps the version and bills the control
    plane at $0.60/hr instead of $0.10 — an extra ~$365/mo per cluster.

    Defaults to STANDARD deliberately: an unattended minor upgrade is a smaller
    problem than a 6x bill nobody notices, and AWS gives months of notice. Keep
    `kubernetes_version` current and this never fires.
  EOT
  type        = string
  default     = "STANDARD"

  validation {
    condition     = contains(["STANDARD", "EXTENDED"], var.cluster_support_type)
    error_message = "cluster_support_type must be STANDARD or EXTENDED."
  }
}

variable "tags" {
  description = "Tags applied to every resource created by this module (cost allocation, `cluster=prod|test`)."
  type        = map(string)
  default     = {}
}

# ---------------------------------------------------------------------------
# network
# ---------------------------------------------------------------------------

variable "vpc_cidr" {
  description = "CIDR block for this cluster's VPC. Each cluster gets its own VPC; the blocks need not be routable to one another."
  type        = string
  default     = "10.0.0.0/16"
}

variable "az_count" {
  description = "Number of availability zones to spread private subnets across."
  type        = number
  default     = 3
}

variable "enable_public_ingress" {
  description = <<-EOT
    Whether this cluster hosts internet-facing ALBs. Public subnets (and the NAT
    gateway that lives in them) are created either way — nodes need egress — but
    the `kubernetes.io/role/elb` tags that let EKS Auto Mode place an
    internet-facing ALB are only applied when this is true.
  EOT
  type        = bool
  default     = false
}

# ---------------------------------------------------------------------------
# compute (EKS Auto Mode NodePool policy)
# ---------------------------------------------------------------------------

variable "builtin_node_pools" {
  description = <<-EOT
    Use EKS Auto Mode's built-in node pools (`general-purpose`, `system`)
    instead of the NodePool this module declares. AWS then owns the node role,
    security groups, and instance profile end to end — the well-trodden path.

    Empty uses the custom NodeClass/NodePool below, which is what buys spot
    capacity and the consolidation policy — and which the `nodepool_*` variables
    configure. They are ignored otherwise.

    Defaults to the built-in pool: it is the path AWS tests, and spot is a poor
    fit for the workloads here anyway. PR environments run neo4j on a
    ReadWriteOnce volume, so every spot rebalance recommendation — which
    Karpenter acts on, and which fires far more often than real interruptions —
    means detaching and reattaching a database volume, potentially mid-test. The
    saving is under $10/mo on a cluster that is idle most of the month.
  EOT
  type        = list(string)
  default     = ["general-purpose"]
}

variable "helm_timeout" {
  description = "Seconds `helm_release` waits for resources to become ready. The default of 300 is tight on a cold cluster, where the first release waits out node provisioning and an image pull before anything can be ready."
  type        = number
  default     = 900
}

variable "nodepool_capacity_types" {
  description = "Capacity types the default NodePool may provision, in preference order as understood by Karpenter (`on-demand`, `spot`)."
  type        = list(string)
  default     = ["on-demand"]
}

variable "nodepool_instance_categories" {
  description = "EC2 instance categories the NodePool may provision."
  type        = list(string)
  default     = ["c", "m", "r"]
}

variable "nodepool_instance_sizes" {
  description = "EC2 instance sizes the NodePool may provision. Empty means no size restriction."
  type        = list(string)
  default     = []
}

variable "nodepool_architectures" {
  description = "CPU architectures the NodePool may provision. Add `arm64` only once multi-arch images are published (see the cost section of the design doc)."
  type        = list(string)
  default     = ["amd64"]
}

variable "nodepool_cpu_limit" {
  description = "Hard ceiling on total vCPU the NodePool may provision — the backstop against a runaway scale-up bill."
  type        = number
  default     = 64
}

variable "nodepool_consolidation_policy" {
  description = "Karpenter consolidation policy: `WhenEmpty` (only reclaim empty nodes) or `WhenEmptyOrUnderutilized` (also repack)."
  type        = string
  default     = "WhenEmptyOrUnderutilized"

  validation {
    condition     = contains(["WhenEmpty", "WhenEmptyOrUnderutilized"], var.nodepool_consolidation_policy)
    error_message = "nodepool_consolidation_policy must be WhenEmpty or WhenEmptyOrUnderutilized."
  }
}

variable "nodepool_consolidate_after" {
  description = "How long a node must sit empty/underutilized before consolidation reclaims it."
  type        = string
  default     = "5m"
}

variable "nodepool_expire_after" {
  description = "Maximum node lifetime before Auto Mode replaces it (node hygiene/patching); `Never` disables."
  type        = string
  default     = "336h"
}

variable "nodepool_disruption_budgets" {
  description = "Karpenter disruption budgets for the default NodePool."
  type = list(object({
    nodes    = string
    reasons  = optional(list(string))
    schedule = optional(string)
    duration = optional(string)
  }))
  default = [{ nodes = "10%" }]
}

variable "storage_class_default" {
  description = "Whether the gp3 StorageClass created by this module is the cluster default. EKS Auto Mode ships no StorageClass of its own."
  type        = bool
  default     = true
}

variable "storage_class_tags" {
  description = "Tags applied to every EBS volume provisioned from the gp3 StorageClass. The DLM snapshot policy selects volumes by these."
  type        = map(string)
  default     = {}
}

variable "storage_class_reclaim_policy" {
  description = "What happens to an EBS volume when its PVC is deleted. `Retain` on prod (a database outlives an accidental namespace delete), `Delete` on test (PR teardown must not leak volumes)."
  type        = string
  default     = "Delete"

  validation {
    condition     = contains(["Retain", "Delete"], var.storage_class_reclaim_policy)
    error_message = "storage_class_reclaim_policy must be Retain or Delete."
  }
}

# ---------------------------------------------------------------------------
# access
# ---------------------------------------------------------------------------

variable "endpoint_public_access_cidrs" {
  description = "CIDRs allowed to reach the public API server endpoint. GitHub-hosted runners have no stable egress range, so this is `0.0.0.0/0` by default; access is still gated by IAM access entries."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "access_entries" {
  description = "EKS access entries (IAM principal -> access policy) for this cluster, passed through to the EKS module. This is where operator admin access and the CD deployer roles are granted."
  type = map(object({
    kubernetes_groups = optional(list(string))
    principal_arn     = string
    type              = optional(string, "STANDARD")
    user_name         = optional(string)
    policy_associations = optional(map(object({
      policy_arn = string
      access_scope = object({
        namespaces = optional(list(string))
        type       = string
      })
    })), {})
  }))
  default = {}
}

# ---------------------------------------------------------------------------
# cluster services
# ---------------------------------------------------------------------------

variable "log_group_name" {
  description = "CloudWatch log group container logs are shipped to by Fluent Bit. Created outside this module so that destroying a cluster never destroys its logs."
  type        = string
}

variable "enable_container_insights" {
  description = "Install the AWS-managed `amazon-cloudwatch-observability` add-on for Container Insights metrics. Its own log collection is disabled — Fluent Bit owns logs."
  type        = bool
  default     = false
}

variable "enable_external_dns" {
  description = "Install ExternalDNS, which creates Route53 records from Ingress hostnames."
  type        = bool
  default     = false
}

variable "external_dns_zone_id" {
  description = "Route53 hosted zone ID ExternalDNS is allowed to write to. Required when `enable_external_dns` is true."
  type        = string
  default     = null
}

variable "external_dns_domain_filters" {
  description = "Domains ExternalDNS will manage records within."
  type        = list(string)
  default     = []
}

variable "external_dns_exclude_domains" {
  description = "Domains ExternalDNS must never touch — used to fence off hostnames still served by the legacy EC2 hosts during migration."
  type        = list(string)
  default     = []
}

variable "external_dns_protected_record_names" {
  description = <<-EOT
    Record names ExternalDNS is denied from changing at the IAM layer, whatever
    its configuration says. Use for names in this zone that point at systems
    outside this cluster — the legacy instances during migration.

    Expressed as a deny rather than an allow-list on purpose: an allow-list has
    to enumerate the TXT-registry ownership records ExternalDNS creates
    alongside each record (`a-<name>`, `cname-<name>`, and the bare name), and
    getting that wrong breaks DNS management silently. A deny on a handful of
    known names cannot.
  EOT
  type        = list(string)
  default     = []
}

variable "external_dns_policy" {
  description = "ExternalDNS record policy. `upsert-only` never deletes records, which is the safe default while legacy instances are still live; `sync` reclaims records for deleted Ingresses."
  type        = string
  default     = "upsert-only"
}

variable "enable_external_secrets" {
  description = "Install External Secrets Operator plus a ClusterSecretStore backed by AWS Secrets Manager."
  type        = bool
  default     = false
}

variable "external_secrets_path_prefix" {
  description = "Secrets Manager path prefix the ESO controller may read (`alchemiscale/*`)."
  type        = string
  default     = "alchemiscale/*"
}

# chart versions are pinned here so both clusters move together and upgrades are
# a reviewable diff rather than a surprise on the next apply
variable "chart_versions" {
  description = "Pinned Helm chart versions for the self-managed cluster services."
  type = object({
    metrics_server     = optional(string, "3.13.1")
    aws_for_fluent_bit = optional(string, "0.2.0")
    external_dns       = optional(string, "1.21.1")
    external_secrets   = optional(string, "2.9.0")
  })
  default = {}
}
