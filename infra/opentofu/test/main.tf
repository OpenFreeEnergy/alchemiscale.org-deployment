# The ephemeral test cluster.
#
# Everything here is disposable: `test-cluster-lifecycle.yml` applies it on
# demand when a PR is labelled `test-deploy`, and destroys it once no test
# environments remain. Nothing stateful lives on it, so a destroy loses nothing
# but the ~20 minutes it takes to build again.
#
# The durable pieces this stack depends on — the log group, the OIDC deployer
# roles, the scratch bucket — are declared in the identity root module and
# looked up here, precisely so `tofu destroy` cannot remove the means of
# bringing the cluster back.

data "aws_partition" "current" {}

# Optional so that this stack can be applied entirely on its own, with only the
# bootstrap layer present — which is what quickstart.md does. The normal path
# applies `identity/` first and leaves this at its default. Set
# `deploy_pr_role_name = ""` to skip.
data "aws_iam_role" "deploy_pr" {
  count = var.deploy_pr_role_name != "" ? 1 : 0

  name = var.deploy_pr_role_name
}

# Normally declared in the identity root module, so the reaper can never destroy
# the logs of the run being investigated. Standing this cluster up standalone
# means there is nothing to have created it — see `create_log_group`.
resource "aws_cloudwatch_log_group" "test" {
  count = var.create_log_group ? 1 : 0

  name              = var.log_group_name
  retention_in_days = var.log_retention_days

  tags = {
    cluster = "test"
  }
}

module "cluster" {
  source = "../modules/cluster"

  cluster_name       = var.cluster_name
  kubernetes_version = var.kubernetes_version
  region             = var.region
  vpc_cidr           = var.vpc_cidr

  # Deliberately lean: no public ingress at all (smoke tests run in-cluster
  # against Service DNS), therefore no ExternalDNS, no External Secrets, and no
  # monitoring stack. PR environments' signal is the smoke test.
  enable_public_ingress     = false
  enable_container_insights = false
  enable_external_dns       = false
  enable_external_secrets   = false

  log_group_name = var.log_group_name

  builtin_node_pools = var.builtin_node_pools

  # spot-first with aggressive consolidation and a short node lifetime: with
  # Auto Mode there is no controller node to keep alive, so an idle test cluster
  # runs zero EC2 instances
  nodepool_capacity_types       = ["spot", "on-demand"]
  nodepool_instance_categories  = ["c", "m", "r", "t"]
  nodepool_cpu_limit            = 32
  nodepool_consolidation_policy = "WhenEmptyOrUnderutilized"
  nodepool_consolidate_after    = "1m"
  nodepool_expire_after         = "24h"
  nodepool_disruption_budgets   = [{ nodes = "100%" }]

  # PR teardown deletes namespaces routinely; volumes must go with them
  storage_class_reclaim_policy = "Delete"

  access_entries = merge(
    {
      for arn in var.admin_principal_arns : "admin-${md5(arn)}" => {
        principal_arn = arn
        policy_associations = {
          admin = {
            policy_arn   = "arn:${data.aws_partition.current.partition}:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
            access_scope = { type = "cluster" }
          }
        }
      }
    },
    # The PR deployer is cluster-admin *here* — it has to create and delete
    # namespaces on demand — and has no access entry on prod whatsoever. The
    # cluster boundary, not RBAC, is what protects production.
    {
      for role in data.aws_iam_role.deploy_pr : "deploy-pr" => {
        principal_arn = role.arn
        policy_associations = {
          admin = {
            policy_arn   = "arn:${data.aws_partition.current.partition}:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
            access_scope = { type = "cluster" }
          }
        }
      }
    },
  )

  tags = {
    cluster = "test"
  }
}
