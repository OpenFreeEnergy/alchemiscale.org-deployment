variable "region" {
  description = "AWS region hosting the test cluster. Must match the identity layer's, so the durable resources declared there resolve."
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "Name of the test EKS cluster."
  type        = string
  default     = "alchemiscale-test"
}

variable "kubernetes_version" {
  description = <<-EOT
    Kubernetes version for the test control plane. `null` (the default) lets EKS
    pick its current default version at creation, so a cluster recreated by the
    lifecycle workflow always comes up on the latest recommended version without
    anyone editing this file.

    That means test can lead prod by a version — deliberately. The chart is
    exercised against the newer version in PR environments before prod is
    upgraded to it, and a mismatch is the prompt to schedule that upgrade. Pin
    this to prod's version if you would rather have exact parity.
  EOT
  type        = string
  default     = null
}

variable "vpc_cidr" {
  description = "CIDR for the test VPC."
  type        = string
  default     = "10.20.0.0/16"
}

variable "builtin_node_pools" {
  description = "EKS Auto Mode built-in node pools, used instead of the module's custom NodeClass/NodePool. Matches prod, so PR environments run the same node configuration as production. See docs/infrastructure.md#node-pools."
  type        = list(string)
  default     = ["general-purpose"]
}

variable "admin_principal_arns" {
  description = "IAM principals granted cluster-admin on the test cluster — needed for port-forwarding into PR environments and for debugging failed smoke tests."
  type        = list(string)
  default     = []
}

variable "deploy_pr_role_name" {
  description = <<-EOT
    Name of the PR deployer role, declared in the identity root module (the
    layer this stack's destruction never touches). Set to "" to stand this
    cluster up with only the bootstrap layer applied — CD cannot deploy to it
    until the role has an access entry, but everything else works.
  EOT
  type        = string
  default     = "alchemiscale-deploy-pr"
}

variable "log_group_name" {
  description = "CloudWatch log group Fluent Bit ships to. Normally declared in the identity root module so logs survive the reaper."
  type        = string
  default     = "alchemiscale-test"
}

variable "create_log_group" {
  description = <<-EOT
    Create the log group here rather than expecting the identity root module to
    own it. For standing this cluster up on its own; leave false in the real
    deployment, or the reaper will take the logs with it.

    Handing it over afterwards means moving it between states rather than
    recreating it:

      tofu -chdir=infra/opentofu/test state rm aws_cloudwatch_log_group.test[0]
      tofu -chdir=infra/opentofu/identity import aws_cloudwatch_log_group.test alchemiscale-test
  EOT
  type        = bool
  default     = false
}

variable "log_retention_days" {
  description = "Retention on the log group, when this module creates it."
  type        = number
  default     = 14
}
