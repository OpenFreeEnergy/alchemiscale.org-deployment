# The principal running `apply` is granted cluster-admin automatically
# (`enable_cluster_creator_admin_permissions` below), so listing it in
# `access_entries` as well asks EKS to create two entries for one principal —
# which fails with a 409 partway through the apply, after the cluster exists.
#
# Listing yourself is the natural thing to do, so drop the duplicate rather than
# documenting the trap. Note this matches on the exact ARN: an entry written
# without the role's IAM path (as SSO roles are sometimes quoted) will not be
# recognised as the same principal.
data "aws_iam_session_context" "current" {
  arn = data.aws_caller_identity.current.arn
}

locals {
  access_entries = {
    for name, entry in var.access_entries : name => entry
    if entry.principal_arn != data.aws_iam_session_context.current.issuer_arn
  }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.25"

  name               = var.cluster_name
  kubernetes_version = var.kubernetes_version
  region             = var.region

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # EKS Auto Mode: AWS operates node lifecycle (Karpenter), load balancing, EBS
  # CSI and core networking. Capacity policy (spot vs on-demand, consolidation,
  # expiry) lives in the NodePool declared in cluster-resources/ instead of the
  # built-in node pools.
  #
  # `node_pools = null`, not `[]`: the module passes the node role to
  # CreateCluster whenever node_pools is non-null, and the API rejects a node
  # role without node pools ("When Compute Config nodeRoleArn is not null or
  # empty, nodePool value(s) must be provided"). Null leaves both out, which is
  # the bring-your-own-NodePool configuration. Storage and load balancing follow
  # `enabled`, so EBS CSI and ALB provisioning are unaffected.
  compute_config = {
    enabled    = true
    node_pools = length(var.builtin_node_pools) > 0 ? var.builtin_node_pools : null
  }

  # access entries only; no aws-auth ConfigMap
  authentication_mode                      = "API"
  access_entries                           = local.access_entries
  enable_cluster_creator_admin_permissions = true

  # CD workflows and operators reach the API server from outside the VPC
  endpoint_public_access       = true
  endpoint_public_access_cidrs = var.endpoint_public_access_cidrs
  endpoint_private_access      = true

  enabled_log_types                      = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
  cloudwatch_log_group_retention_in_days = 90

  node_security_group_tags = local.discovery_tags

  tags = var.tags
}

# Nodes launched from our own NodeClass authenticate with the node IAM role,
# which EKS only trusts if it has an access entry. When the node role is handed
# to CreateCluster this is implicit; taking the bring-your-own-NodePool route
# above means declaring it. Without this, nodes launch and never register, and
# pods sit Pending with no obvious cause.
resource "aws_eks_access_entry" "node" {
  # only for the custom path; with built-in node pools the node role is handed
  # to CreateCluster and EKS registers it itself
  count = length(var.builtin_node_pools) > 0 ? 0 : 1

  cluster_name  = module.eks.cluster_name
  principal_arn = module.eks.node_iam_role_arn
  type          = "EC2"

  tags = var.tags
}

# Container Insights. Log collection is disabled: Fluent Bit (below) owns
# container logs and ships them to the long-lived alchemiscale log group, and
# running both would double both the pipeline and the ingest bill.
resource "aws_eks_addon" "cloudwatch_observability" {
  count = var.enable_container_insights ? 1 : 0

  cluster_name = module.eks.cluster_name
  addon_name   = "amazon-cloudwatch-observability"

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  configuration_values = jsonencode({
    containerLogs = { enabled = false }
    agent = {
      config = {
        logs = {
          metrics_collected = {
            kubernetes = {
              enhanced_container_insights = true
            }
          }
        }
      }
    }
  })

  pod_identity_association {
    role_arn        = aws_iam_role.cloudwatch_observability[0].arn
    service_account = "cloudwatch-agent"
  }

  tags = var.tags

  depends_on = [helm_release.cluster_resources]
}
