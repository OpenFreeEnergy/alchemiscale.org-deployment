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
