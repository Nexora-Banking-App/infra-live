# =============================================================================
# 1. PRODUCTION EKS CLUSTER (Multi-AZ High Availability)
# =============================================================================
module "prod_eks" {
  source = "git::https://github.com/Nexora-Banking-App/infra-modules.git//eks?ref=main"

  cluster_name        = "nexora-prod"
  cluster_version     = "1.31"
  environment         = "prod"
  vpc_id              = data.terraform_remote_state.shared.outputs.vpc_id
  subnet_ids          = data.terraform_remote_state.shared.outputs.private_subnets
  node_instance_types = ["c7i-flex.large"]
  desired_size        = 2
  min_size            = 2
  max_size            = 4
}

# =============================================================================
# 2. PRODUCTION MULTI-AZ RDS DATABASE (Synchronous Standby, RPO=0)
# =============================================================================
module "prod_rds" {
  source = "git::https://github.com/Nexora-Banking-App/infra-modules.git//rds?ref=main"

  environment             = "prod"
  vpc_id                  = data.terraform_remote_state.shared.outputs.vpc_id
  subnet_ids              = data.terraform_remote_state.shared.outputs.private_subnets
  instance_class          = "db.t3.medium"
  multi_az                = true # SYNCHRONOUS REPLICATION FOR RPO=0
  backup_retention_period = 7    # 7-DAY PITR RETENTION WINDOW
}

# =============================================================================
# 3. AWS LOAD BALANCER CONTROLLER (IRSA + Helm)
# =============================================================================
module "load_balancer_controller_irsa_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "5.39.0"

  role_name                              = "nexora-prod-load-balancer-controller"
  attach_load_balancer_controller_policy = true

  oidc_providers = {
    ex = {
      provider_arn               = module.prod_eks.oidc_provider_arn
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
  wait       = true # MUST be true to avoid Webhook deadlock
  timeout    = 600

  set {
    name  = "clusterName"
    value = module.prod_eks.cluster_name
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

  depends_on = [module.prod_eks]
}

# =============================================================================
# 4. EXTERNAL SECRETS OPERATOR IAM ROLE (IRSA)
# =============================================================================
module "external_secrets_irsa_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "5.39.0"

  role_name = "nexora-prod-external-secrets"

  role_policy_arns = {
    secrets_read = "arn:aws:iam::aws:policy/SecretsManagerReadWrite"
  }

  oidc_providers = {
    ex = {
      provider_arn               = module.prod_eks.oidc_provider_arn
      namespace_service_accounts = ["external-secrets:external-secrets"]
    }
  }
}

# =============================================================================
# 5. ISTIO SERVICE MESH BASE & CONTROL PLANE
# =============================================================================
resource "helm_release" "istio_base" {
  name             = "istio-base"
  repository       = "https://istio-release.storage.googleapis.com/charts"
  chart            = "base"
  version          = "1.22.0"
  namespace        = "istio-system"
  create_namespace = true
  wait             = true

  depends_on = [helm_release.aws_load_balancer_controller]
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
    value = "100m"
  }

  set {
    name  = "pilot.resources.requests.memory"
    value = "256Mi"
  }

  depends_on = [helm_release.istio_base]
}

# =============================================================================
# 6. ARGO ROLLOUTS CONTROLLER & CRDS
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

  depends_on = [helm_release.aws_load_balancer_controller]
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

  set {
    name  = "configs.cm.kustomize\\.buildOptions"
    value = "--enable-helm"
  }

  depends_on = [
    module.prod_eks,
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

# =============================================================================
# 8. KUBERNETES METRICS SERVER (For HPA)
# =============================================================================
resource "helm_release" "metrics_server" {
  name             = "metrics-server"
  repository       = "https://kubernetes-sigs.github.io/metrics-server/"
  chart            = "metrics-server"
  version          = "3.12.1"
  namespace        = "kube-system"
  create_namespace = true
  wait             = false

  set {
    name  = "args[0]"
    value = "--kubelet-insecure-tls"
  }

  depends_on = [module.prod_eks]
}