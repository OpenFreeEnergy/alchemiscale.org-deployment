# Self-managed cluster services. Everything else a cluster needs — node
# lifecycle, load balancer provisioning, EBS CSI, CNI — is operated by AWS
# under EKS Auto Mode and deliberately does not appear here.

# NodeClass/NodePool/StorageClass. Nothing can be scheduled until this exists,
# so every other release depends on it.
resource "helm_release" "cluster_resources" {
  name      = "cluster-resources"
  chart     = "${path.module}/charts/cluster-resources"
  namespace = "kube-system"

  timeout = var.helm_timeout
  values = [yamlencode({
    clusterName = var.cluster_name

    # skipped entirely when the built-in Auto Mode node pools are in use
    customNodePool = length(var.builtin_node_pools) == 0

    nodeClass = {
      role               = module.eks.node_iam_role_name
      subnetSelectorTags = local.discovery_tags

      # The EKS-managed cluster security group, and *only* that one. This
      # matches the NodeClass AWS generates for its built-in node pools, and it
      # is load-bearing: attaching the module's node security group as well —
      # or instead — produces nodes that register and then sit NotReady forever
      # with "cni plugin not initialized", because Auto Mode's pod ENIs inherit
      # the node's security groups and its managed networking expects exactly
      # this group. Verified by diffing against the AWS-managed NodeClass on a
      # working cluster.
      securityGroupIds = [module.eks.cluster_primary_security_group_id]
    }

    nodePool = {
      capacityTypes       = var.nodepool_capacity_types
      architectures       = var.nodepool_architectures
      instanceCategories  = var.nodepool_instance_categories
      instanceSizes       = var.nodepool_instance_sizes
      cpuLimit            = var.nodepool_cpu_limit
      expireAfter         = var.nodepool_expire_after
      consolidationPolicy = var.nodepool_consolidation_policy
      consolidateAfter    = var.nodepool_consolidate_after
      disruptionBudgets   = var.nodepool_disruption_budgets
    }

    ingressClass = {
      enabled = var.enable_public_ingress
      name    = "alb"
      scheme  = "internet-facing"
    }

    storageClass = {
      default       = var.storage_class_default
      reclaimPolicy = var.storage_class_reclaim_policy
      tags          = [for k, v in var.storage_class_tags : { key = k, value = v }]
    }
  })]

  # the access entry is what lets nodes from this NodePool actually register
  depends_on = [module.eks, aws_eks_access_entry.node]
}

resource "helm_release" "metrics_server" {
  name       = "metrics-server"
  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"
  version    = var.chart_versions.metrics_server
  namespace  = "kube-system"

  timeout = var.helm_timeout
  values = [yamlencode({
    resources = {
      requests = { cpu = "50m", memory = "100Mi" }
      limits   = { memory = "200Mi" }
    }
  })]

  depends_on = [helm_release.cluster_resources]
}

# Container logs -> CloudWatch. Replaces the `awslogs` docker-compose logging
# driver the EC2 hosts use; the log group itself is declared outside this module
# so that destroying the test cluster never destroys its logs.
resource "helm_release" "fluent_bit" {
  name       = "aws-for-fluent-bit"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-for-fluent-bit"
  version    = var.chart_versions.aws_for_fluent_bit
  namespace  = "kube-system"

  timeout = var.helm_timeout
  values = [yamlencode({
    serviceAccount = {
      create = true
      name   = "aws-for-fluent-bit"
    }

    cloudWatchLogs = {
      enabled         = true
      region          = var.region
      logGroupName    = var.log_group_name
      autoCreateGroup = false
      # one stream per container, namespaced — mirrors the compose `tag` option
      logStreamTemplate = "$kubernetes['namespace_name'].$kubernetes['pod_name'].$kubernetes['container_name']"
    }

    # CloudWatch only; the other outputs the chart bundles stay off
    firehose      = { enabled = false }
    kinesis       = { enabled = false }
    elasticsearch = { enabled = false }
    opensearch    = { enabled = false }

    resources = {
      requests = { cpu = "50m", memory = "100Mi" }
      limits   = { memory = "250Mi" }
    }
  })]

  depends_on = [
    helm_release.cluster_resources,
    aws_eks_pod_identity_association.fluent_bit,
  ]
}

# Route53 records from Ingress hostnames. Prod only — the test cluster has no
# public ingress to publish.
resource "helm_release" "external_dns" {
  count = var.enable_external_dns ? 1 : 0

  name       = "external-dns"
  repository = "https://kubernetes-sigs.github.io/external-dns/"
  chart      = "external-dns"
  version    = var.chart_versions.external_dns
  namespace  = "kube-system"

  timeout = var.helm_timeout
  values = [yamlencode({
    provider = { name = "aws" }

    serviceAccount = {
      create = true
      name   = "external-dns"
    }

    sources        = ["ingress"]
    policy         = var.external_dns_policy
    registry       = "txt"
    txtOwnerId     = var.cluster_name
    domainFilters  = var.external_dns_domain_filters
    excludeDomains = var.external_dns_exclude_domains

    extraArgs = [
      "--aws-zone-type=public",
      "--zone-id-filter=${var.external_dns_zone_id}",
    ]

    resources = {
      requests = { cpu = "25m", memory = "64Mi" }
      limits   = { memory = "128Mi" }
    }
  })]

  depends_on = [
    helm_release.cluster_resources,
    aws_eks_pod_identity_association.external_dns,
  ]
}

# Secrets Manager -> Kubernetes Secrets. Prod only; PR namespaces generate
# throwaway credentials in-chart instead.
resource "helm_release" "external_secrets" {
  count = var.enable_external_secrets ? 1 : 0

  name             = "external-secrets"
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  version          = var.chart_versions.external_secrets
  namespace        = "external-secrets"
  create_namespace = true

  timeout = var.helm_timeout
  values = [yamlencode({
    installCRDs = true

    serviceAccount = {
      create = true
      name   = "external-secrets"
    }

    resources = {
      requests = { cpu = "50m", memory = "128Mi" }
      limits   = { memory = "256Mi" }
    }
  })]

  depends_on = [
    helm_release.cluster_resources,
    aws_eks_pod_identity_association.external_secrets,
  ]
}

resource "helm_release" "secret_store" {
  count = var.enable_external_secrets ? 1 : 0

  name      = "secret-store"
  chart     = "${path.module}/charts/secret-store"
  namespace = "external-secrets"

  timeout = var.helm_timeout
  values = [yamlencode({
    name   = "aws-secrets-manager"
    region = var.region
  })]

  depends_on = [helm_release.external_secrets]
}
