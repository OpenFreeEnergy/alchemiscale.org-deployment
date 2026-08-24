output "cluster_name" {
  description = "Name of the EKS cluster (what `aws eks update-kubeconfig --name` takes)."
  value       = module.eks.cluster_name
}

output "cluster_arn" {
  description = "ARN of the EKS cluster."
  value       = module.eks.cluster_arn
}

output "cluster_endpoint" {
  description = "Kubernetes API server endpoint."
  value       = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64-encoded CA bundle for the API server."
  value       = module.eks.cluster_certificate_authority_data
}

output "vpc_id" {
  description = "ID of the VPC this cluster runs in."
  value       = module.vpc.vpc_id
}

output "private_subnet_ids" {
  description = "Private subnet IDs (nodes)."
  value       = module.vpc.private_subnets
}

output "public_subnet_ids" {
  description = "Public subnet IDs (NAT gateway, and ALBs where public ingress is enabled)."
  value       = module.vpc.public_subnets
}

output "node_iam_role_arn" {
  description = "IAM role EKS Auto Mode attaches to nodes."
  value       = module.eks.node_iam_role_arn
}

output "oidc_provider_arn" {
  description = "ARN of the cluster's IRSA OIDC provider, for anything that cannot use Pod Identity."
  value       = module.eks.oidc_provider_arn
}
