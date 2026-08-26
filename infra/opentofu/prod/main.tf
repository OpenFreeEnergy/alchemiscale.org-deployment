data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

# The deployer roles live in the identity root module, which is applied first —
# looked up by name rather than declared, so this module can grant the release
# role an access entry without owning it. Optional in the same way `test/`'s
# lookup is: set `deploy_release_role_name = ""` to apply the cluster before the
# identity layer exists, at the cost of release CD having no way in.
data "aws_iam_role" "deploy_release" {
  count = var.deploy_release_role_name != "" ? 1 : 0

  name = var.deploy_release_role_name
}

locals {
  # hostnames each deployment answers on
  deployment_hosts = {
    for name, dep in var.deployments : name => {
      client  = "api.${dep.domain}"
      compute = "compute.${dep.domain}"
    }
  }

  backups_bucket_name = coalesce(var.backups_bucket_name, "alchemiscale-backups-${data.aws_caller_identity.current.account_id}")

  # Kubernetes group the release deployer lands in, so it can be granted the
  # small cluster-scoped read it needs on top of its namespace-scoped admin.
  deployer_group = "alchemiscale-deployers"
}

module "cluster" {
  source = "../modules/cluster"

  cluster_name       = var.cluster_name
  kubernetes_version = var.kubernetes_version
  region             = var.region
  vpc_cidr           = var.vpc_cidr

  # production serves the public internet: ALB-eligible public subnets, DNS,
  # secrets, and metrics all on
  enable_public_ingress     = true
  enable_container_insights = true
  enable_external_dns       = true
  enable_external_secrets   = true

  external_dns_zone_id         = data.aws_route53_zone.main.zone_id
  external_dns_domain_filters  = [var.hosted_zone_name]
  external_dns_exclude_domains = var.legacy_dns_names
  # belt and braces: the exclusion above is configuration, this is permission
  external_dns_protected_record_names = var.legacy_dns_names

  log_group_name = aws_cloudwatch_log_group.prod.name

  builtin_node_pools = var.builtin_node_pools

  # steady state is two to three general-purpose nodes carrying all deployments
  # plus the handful of small controllers; the limit is a runaway backstop
  nodepool_capacity_types      = ["on-demand"]
  nodepool_instance_categories = ["c", "m", "r"]
  nodepool_cpu_limit           = 64
  nodepool_consolidate_after   = "10m"
  nodepool_expire_after        = "336h"
  nodepool_disruption_budgets = [
    # never take more than one node at a time, and leave databases alone during
    # the working day
    { nodes = "1" },
    { nodes = "0", schedule = "0 13 * * mon-fri", duration = "8h", reasons = ["Underutilized"] },
  ]

  storage_class_reclaim_policy = "Retain"
  storage_class_tags           = { "alchemiscale-snapshot" = "true" }

  access_entries = merge(
    # operators: full cluster admin, needed for identity administration,
    # neo4j dump/restore, and general incident response
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
    # release CD: namespace-scoped admin over the production namespaces only.
    # Note what is absent: the PR deployer role has no entry here at all, so a
    # compromised PR workflow has no path to production.
    {
      for role in data.aws_iam_role.deploy_release : "release" => {
        principal_arn     = role.arn
        kubernetes_groups = [local.deployer_group]
        policy_associations = {
          admin = {
            policy_arn = "arn:${data.aws_partition.current.partition}:eks::aws:cluster-access-policy/AmazonEKSAdminPolicy"
            access_scope = {
              type       = "namespace"
              namespaces = keys(var.deployments)
            }
          }
        }
      }
    },
  )

  tags = {
    cluster = "prod"
  }
}

# One namespace per deployment, created here rather than by `helm
# --create-namespace`, which is what lets the release role stay namespace-scoped.
resource "kubernetes_namespace_v1" "deployment" {
  for_each = var.deployments

  metadata {
    name = each.key

    labels = {
      "app.kubernetes.io/part-of" = "alchemiscale"
      "alchemiscale.org/instance" = each.key
    }
  }

  depends_on = [module.cluster]
}

# `helm upgrade` resolves the target namespace before touching anything in it;
# EKS namespace-scoped access policies do not carry that cluster-scoped read.
resource "kubernetes_cluster_role_v1" "namespace_reader" {
  metadata {
    name = "alchemiscale-namespace-reader"
  }

  rule {
    api_groups = [""]
    resources  = ["namespaces"]
    verbs      = ["get", "list", "watch"]
  }

  depends_on = [module.cluster]
}

resource "kubernetes_cluster_role_binding_v1" "namespace_reader" {
  metadata {
    name = "alchemiscale-namespace-reader"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role_v1.namespace_reader.metadata[0].name
  }

  subject {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Group"
    name      = local.deployer_group
  }
}
