module "shared_vpc" {
  source = "git::https://github.com/Nexora-Banking-App/infra-modules.git//vpc?ref=main"

  environment     = "shared"
  vpc_cidr        = "10.0.0.0/16"
  public_subnets  = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  private_subnets = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]
}