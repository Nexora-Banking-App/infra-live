# 1. Staging EKS Cluster
module "staging_eks" {
  source = "git::https://github.com/Nexora-Banking-App/infra-modules.git//eks?ref=main"

  cluster_name        = "nexora-staging"
  cluster_version     = "1.32"
  environment         = "staging"
  vpc_id              = data.terraform_remote_state.shared.outputs.vpc_id
  subnet_ids          = data.terraform_remote_state.shared.outputs.private_subnets
  node_instance_types = ["c7i-flex.large"] # Use t3.micro for Free Tier, t3.small for more power
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
  backup_retention_period = 1
}

# 3. Declarative GitOps Engine: ArgoCD
resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "6.7.18"
  namespace        = "argocd"
  create_namespace = true
  wait             = false
  timeout          = 600

  set {
    name  = "server.service.type"
    value = "ClusterIP"
  }

  set {
    name  = "configs.cm.kustomize\\.buildOptions"
    value = "--enable-helm"
  }

  depends_on = [
    module.staging_eks,
    helm_release.aws_load_balancer_controller
  ]
}

# 4. AWS LOAD BALANCER CONTROLLER (Native Ingress via ALBs)
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

resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = "1.7.2"
  namespace  = "kube-system"
  wait       = false
  timeout    = 600

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

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.load_balancer_controller_irsa_role.iam_role_arn
  }

  depends_on = [module.staging_eks]
}

# 5. EXTERNAL SECRETS OPERATOR IAM ROLE (IRSA)
module "external_secrets_irsa_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "5.39.0"

  role_name = "nexora-staging-external-secrets"

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

# =============================================================================
# 6. ARGOCD ROOT APP-OF-APPS BOOTSTRAP (100% Hands-Free GitOps)
# =============================================================================
resource "helm_release" "argocd_root_app" {
  name       = "argocd-root-app"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  version    = "2.0.0"
  namespace  = "argocd"
  wait       = false

  values = [
    yamlencode({
      applications = [
        {
          name      = "platform-bootstrap"
          namespace = "argocd"
          project   = "default"
          source = {
            # Tells ArgoCD to look at the apps/ folder in platform-config!
            repoURL        = "https://github.com/Nexora-Banking-App/platform-config.git"
            targetRevision = "HEAD"
            path           = "apps"
          }
          destination = {
            server    = "https://kubernetes.default.svc"
            namespace = "argocd"
          }
          syncPolicy = {
            automated = {
              prune    = true
              selfHeal = true
            }
          }
        }
      ]
    })
  ]

  depends_on = [
    helm_release.argocd # Wait for ArgoCD to be installed first
  ]
}