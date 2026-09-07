output "vpc_id" {
  value = module.shared_vpc.vpc_id
}

output "private_subnets" {
  value = module.shared_vpc.private_subnets
}

output "public_subnets" {
  value = module.shared_vpc.public_subnets
}