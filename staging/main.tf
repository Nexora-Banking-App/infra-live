# 1. Staging EKS Cluster
module "staging_eks" {
  source = "git::https://github.com/Nexora-Banking-App/infra-modules.git//eks?ref=main"

  cluster_name        = "nexora-staging"
  cluster_version     = "1.35" 
  environment         = "staging"
  vpc_id              = data.terraform_remote_state.shared.outputs.vpc_id
  subnet_ids          = data.terraform_remote_state.shared.outputs.private_subnets
  node_instance_types = ["t3.medium"]
  desired_size        = 2
  min_size            = 1
  max_size            = 3
}
# 2. Independent Staging Database (Single-AZ to save cost)
module "staging_rds" {
  source = "git::https://github.com/Nexora-Banking-App/infra-modules.git//rds?ref=main"

  environment             = "staging"
  vpc_id                  = data.terraform_remote_state.shared.outputs.vpc_id
  subnet_ids              = data.terraform_remote_state.shared.outputs.private_subnets
  eks_security_group_id   = module.staging_eks.cluster_security_group_id
  instance_class          = "db.t3.micro"
  multi_az                = false
  backup_retention_period = 1 # <-- Complies with Free Tier limits
}