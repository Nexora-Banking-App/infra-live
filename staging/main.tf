# =============================================================================
# 1. EKS KUBERNETES CLUSTER (v1.31 on AL2023 t3.micro)
# =============================================================================
module "staging_eks" {
  source = "git::https://github.com/Nexora-Banking-App/infra-modules.git//eks?ref=main"

  cluster_name        = "nexora-staging"
  cluster_version     = "1.32"
  environment         = "staging"
  vpc_id              = data.terraform_remote_state.shared.outputs.vpc_id
  subnet_ids          = data.terraform_remote_state.shared.outputs.private_subnets
  node_instance_types = ["c7i-flex.large"]
  desired_size        = 2
  min_size            = 1
  max_size            = 3
}

# =============================================================================
# 2. INDEPENDENT STAGING RDS MYSQL DATABASE
# =============================================================================
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

# =============================================================================
# 3. AWS LOAD BALANCER CONTROLLER (IRSA + Helm)
# =============================================================================
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

# =============================================================================
# 4. EXTERNAL SECRETS OPERATOR IAM ROLE (IRSA)
# =============================================================================
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
# 5. ISTIO SERVICE MESH BASE & CONTROL PLANE (Automated Helm Bootstrap)
# =============================================================================
resource "helm_release" "istio_base" {
  name             = "istio-base"
  repository       = "https://istio-release.storage.googleapis.com/charts"
  chart            = "base"
  version          = "1.22.0"
  namespace        = "istio-system"
  create_namespace = true
  wait             = true

  depends_on = [module.staging_eks]
}

resource "helm_release" "istiod" {
  name             = "istiod"
  repository       = "https://istio-release.storage.googleapis.com/charts"
  chart            = "istiod"
  version          = "1.22.0"
  namespace        = "istio-system"
  create_namespace = true
  wait             = false

  set {
    name  = "pilot.resources.requests.cpu"
    value = "50m"
  }

  set {
    name  = "pilot.resources.requests.memory"
    value = "128Mi"
  }

  depends_on = [helm_release.istio_base]
}

# =============================================================================
# 6. ARGO ROLLOUTS CONTROLLER & CRDS (Automated Helm Bootstrap)
# =============================================================================
resource "helm_release" "argo_rollouts" {
  name             = "argo-rollouts"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-rollouts"
  version          = "2.37.1"
  namespace        = "argo-rollouts"
  create_namespace = true
  wait             = false

  set {
    name  = "installCRDs"
    value = "true"
  }

  depends_on = [module.staging_eks]
}

# =============================================================================
# 7. ARGOCD GITOPS ENGINE & ROOT APP-OF-APPS BOOTSTRAP
# =============================================================================
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

  # Bakes --enable-helm directly into ArgoCD on install
  set {
    name  = "configs.cm.kustomize\\.buildOptions"
    value = "--enable-helm"
  }

  depends_on = [
    module.staging_eks,
    helm_release.aws_load_balancer_controller
  ]
}

resource "helm_release" "argocd_root_app" {
  name       = "argocd-root-app"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  version    = "2.0.0"
  namespace  = "argocd"
  wait       = false

  values = [
    yamlencode({
      applications = {
        platform-bootstrap = {
          namespace = "argocd"
          project   = "default"
          source = {
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
      }
    })
  ]

  depends_on = [
    helm_release.argocd,
    helm_release.istiod,
    helm_release.argo_rollouts
  ]
}