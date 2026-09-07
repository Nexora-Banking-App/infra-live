output "cluster_name" { value = module.staging_eks.cluster_name }
output "cluster_endpoint" { value = module.staging_eks.cluster_endpoint }
output "db_address" { value = module.staging_rds.db_address }
output "secrets_manager_secret_arn" { value = module.staging_rds.secrets_manager_secret_arn }