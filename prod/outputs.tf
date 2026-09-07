output "cluster_name" { value = module.prod_eks.cluster_name }
output "cluster_endpoint" { value = module.prod_eks.cluster_endpoint }
output "db_address" { value = module.prod_rds.db_address }
output "secrets_manager_secret_arn" { value = module.prod_rds.secrets_manager_secret_arn }