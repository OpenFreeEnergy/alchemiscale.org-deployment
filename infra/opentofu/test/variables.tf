variable "region" {
  description = "AWS region hosting the test cluster. Must match prod so the durable resources declared there resolve."
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "Name of the test EKS cluster."
  type        = string
  default     = "alchemiscale-test"
}

variable "kubernetes_version" {
  description = "Kubernetes version for the test control plane. Keep in step with prod — a PR environment that passes on a different version proves less than it appears to."
  type        = string
  default     = "1.33"
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
    Name of the PR deployer role, declared in the prod root module (the layer
    this stack's destruction never touches). Set to "" to stand this cluster up
    before that module exists — CD cannot deploy to it until the role has an
    access entry, but everything else works.
  EOT
  type        = string
  default     = "alchemiscale-deploy-pr"
}

variable "log_group_name" {
  description = "CloudWatch log group Fluent Bit ships to. Normally declared in the prod root module so logs survive the reaper."
  type        = string
  default     = "alchemiscale-test"
}

variable "create_log_group" {
  description = <<-EOT
    Create the log group here rather than expecting the prod root module to own
    it. For standing this cluster up on its own; leave false in the real
    deployment, or the reaper will take the logs with it.

    Handing it over to prod later means moving it between states rather than
    recreating it:

      tofu -chdir=infra/opentofu/test state rm aws_cloudwatch_log_group.test[0]
      tofu -chdir=infra/opentofu/prod import aws_cloudwatch_log_group.test alchemiscale-test
  EOT
  type        = bool
  default     = false
}

variable "log_retention_days" {
  description = "Retention on the log group, when this module creates it."
  type        = number
  default     = 14
}
