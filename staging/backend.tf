terraform {
  required_version = ">= 1.10.0"
  required_providers {
    aws    = { source = "hashicorp/aws", version = "~> 5.0" }
    random = { source = "hashicorp/random", version = "~> 3.5" }
    helm   = { source = "hashicorp/helm", version = "~> 2.13" } # <-- Added Helm
  }

  backend "s3" {
    bucket       = "nexora-tf-state-ahmed"
    key          = "staging/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = "us-east-1"
  default_tags {
    tags = {
      Environment = "staging"
      Project     = "NexoraPlatform"
      ManagedBy   = "Terraform"
    }
  }
}

# Configures Helm to communicate directly with our newly created EKS cluster
provider "helm" {
  kubernetes {
    host                   = module.staging_eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.staging_eks.cluster_certificate_authority_data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      args        = ["eks", "get-token", "--cluster-name", module.staging_eks.cluster_name]
      command     = "aws"
    }
  }
}