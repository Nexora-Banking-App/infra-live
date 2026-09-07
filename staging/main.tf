# 1. Staging EKS Cluster
module "staging_eks" {
  source = "git::https://github.com/Nexora-Banking-App/infra-modules.git//eks?ref=main"

  cluster_name        = "nexora-staging"
  cluster_version     = "1.31"
  environment         = "staging"
  vpc_id              = data.terraform_remote_state.shared.outputs.vpc_id
  subnet_ids          = data.terraform_remote_state.shared.outputs.private_subnets
  node_instance_types = ["t3.small"]
  desired_size        = 4 
  min_size            = 2
  max_size            = 6
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
  backup_retention_period = 1
}

# 3. Declarative GitOps Engine: ArgoCD
# 3. Declarative GitOps Engine: ArgoCD
resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "6.7.18"
  namespace        = "argocd"
  create_namespace = true

  set {
    name  = "server.service.type"
    value = "ClusterIP"
  }

  # AUTOMATED: Bakes the --enable-helm flag into ArgoCD on install!
  set {
    name  = "configs.cm.kustomize\\.buildOptions"
    value = "--enable-helm"
  }

  depends_on = [
    module.staging_eks,
    helm_release.aws_load_balancer_controller
  ]
}

# =============================================================================
# 4. AWS LOAD BALANCER CONTROLLER (Native Ingress via ALBs)
# =============================================================================

# 4a. Create the IAM Role for the Controller via OIDC (IRSA)
module "load_balancer_controller_irsa_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "5.39.0"

  role_name                              = "nexora-staging-load-balancer-controller"
  attach_load_balancer_controller_policy = true

  oidc_providers = {
    ex = {
      provider_arn               = module.staging_eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }
}

# 4b. Install the AWS Load Balancer Controller via Helm
resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = "1.7.2"
  namespace  = "kube-system"

  set {
    name  = "clusterName"
    value = module.staging_eks.cluster_name
  }

  set {
    name  = "serviceAccount.create"
    value = "true"
  }

  set {
    name  = "serviceAccount.name"
    value = "aws-load-balancer-controller"
  }

  # Injects the IAM Role ARN we just created!
  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.load_balancer_controller_irsa_role.iam_role_arn
  }

  depends_on = [module.staging_eks]
}
# =============================================================================
# 5. EXTERNAL SECRETS OPERATOR IAM ROLE (IRSA)
# =============================================================================
module "external_secrets_irsa_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "5.39.0"

  role_name = "nexora-staging-external-secrets"

  # Policy granting read access to AWS Secrets Manager
  role_policy_arns = {
    secrets_read = "arn:aws:iam::aws:policy/SecretsManagerReadWrite"
  }

  oidc_providers = {
    ex = {
      provider_arn               = module.staging_eks.oidc_provider_arn
      namespace_service_accounts = ["external-secrets:external-secrets"]
    }
  }
}