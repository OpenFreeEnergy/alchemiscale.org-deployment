module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.25"

  name               = var.cluster_name
  kubernetes_version = var.kubernetes_version
  region             = var.region

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # EKS Auto Mode: AWS operates node lifecycle (Karpenter), load balancing, EBS
  # CSI and core networking. `node_pools = []` opts out of the two built-in node
  # pools in favour of the NodePool declared in cluster-resources/, which is
  # where this module's capacity policy (spot vs on-demand, consolidation,
  # expiry) actually lives.
  compute_config = {
    enabled    = true
    node_pools = []
  }

  # access entries only; no aws-auth ConfigMap
  authentication_mode                      = "API"
  access_entries                           = var.access_entries
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
