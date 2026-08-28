output "cluster_name" {
  description = "Production cluster name; `aws eks update-kubeconfig --name <this>`."
  value       = module.cluster.cluster_name
}

output "certificate_arns" {
  description = "ACM certificate ARN per deployment. The chart's Ingress discovers its certificate by hostname, so these are for reference and for pinning `ingress.certificateArn` if discovery is ever ambiguous."
  value       = { for name, cert in aws_acm_certificate.deployment : name => cert.arn }
}

output "deployment_role_arns" {
  description = "Pod Identity role per deployment (the identity API pods carry)."
  value       = { for name, role in aws_iam_role.deployment : name => role.arn }
}

# The deployer role ARNs are outputs of the identity root module, not this one.

output "backups_bucket" {
  description = "Bucket neo4j logical dumps are written to by scripts/neo4j-dump.sh."
  value       = aws_s3_bucket.backups.id
}

output "legacy_dns_editor_role_arn" {
  description = "Role the legacy account assumes to edit its own DNS records in this zone; null when no editor accounts are configured."
  value       = try(aws_iam_role.legacy_dns_editor[0].arn, null)
}

output "alerts_topic_arn" {
  description = "SNS topic every alarm routes to."
  value       = aws_sns_topic.alerts.arn
}
