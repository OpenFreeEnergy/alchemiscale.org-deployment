output "cluster_name" {
  description = "Test cluster name; `aws eks update-kubeconfig --name <this>`."
  value       = module.cluster.cluster_name
}

output "cluster_endpoint" {
  description = "Kubernetes API server endpoint."
  value       = module.cluster.cluster_endpoint
}

output "vpc_id" {
  description = "ID of the test VPC."
  value       = module.cluster.vpc_id
}

output "kubernetes_version" {
  description = "Version the cluster actually came up on. With `kubernetes_version = null` this is whatever EKS defaults to today — compare against prod to see when an upgrade is due."
  value       = module.cluster.kubernetes_version
}
