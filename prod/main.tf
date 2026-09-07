# 1. Production EKS Cluster
module "prod_eks" {
  source = "git::https://github.com/Nexora-Banking-App/infra-modules.git//eks?ref=main"

  cluster_name        = "nexora-prod"
  cluster_version     = "1.30"
  environment         = "prod"
  vpc_id              = data.terraform_remote_state.shared.outputs.vpc_id
  subnet_ids          = data.terraform_remote_state.shared.outputs.private_subnets
  node_instance_types = ["t3.large"]
  desired_size        = 2
  min_size            = 2
  max_size            = 4
}

# 2. Production Multi-AZ Database (Synchronous Failover, RPO=0)
module "prod_rds" {
  source = "git::https://github.com/Nexora-Banking-App/infra-modules.git//rds?ref=main"

  environment           = "prod"
  vpc_id                = data.terraform_remote_state.shared.outputs.vpc_id
  subnet_ids            = data.terraform_remote_state.shared.outputs.private_subnets
  eks_security_group_id = module.prod_eks.cluster_security_group_id
  instance_class        = "db.t3.medium"
  multi_az              = true # Enterprise synchronous standby in secondary AZ
}