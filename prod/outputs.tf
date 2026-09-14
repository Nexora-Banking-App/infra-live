output "cluster_name" {
  description = "Production EKS Cluster Name"
  value       = module.prod_eks.cluster_name
}

output "cluster_endpoint" {
  description = "Production EKS API Endpoint"
  value       = module.prod_eks.cluster_endpoint
}

output "db_address" {
  description = "Production Multi-AZ RDS Hostname"
  value       = module.prod_rds.db_address
}

output "secrets_manager_secret_arn" {
  description = "Production AWS Secrets Manager Secret ARN"
  value       = module.prod_rds.secrets_manager_secret_arn
}