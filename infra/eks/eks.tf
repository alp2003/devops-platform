module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.29.0"

  name               = var.cluster_name
  kubernetes_version = var.kubernetes_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  endpoint_public_access       = true
  endpoint_public_access_cidrs = [var.admin_cidr]
  endpoint_private_access      = true

  enable_cluster_creator_admin_permissions = true

  # Role → Kubernetes permissions (roles in access.tf). AWS-managed access policies:
  # View excludes Secrets; Edit allows changing workloads but not RBAC.
  access_entries = {
    admin = {
      principal_arn = aws_iam_role.access["admin"].arn

      policy_associations = {
        cluster_admin = {
          policy_arn   = "${local.eks_access_policy}/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }
    developer = {
      principal_arn = aws_iam_role.access["developer"].arn

      policy_associations = {
        edit_dev = {
          policy_arn   = "${local.eks_access_policy}/AmazonEKSEditPolicy"
          access_scope = { type = "namespace", namespaces = ["web-dev"] }
        }
        view_prod = {
          policy_arn   = "${local.eks_access_policy}/AmazonEKSViewPolicy"
          access_scope = { type = "namespace", namespaces = ["web-prod"] }
        }
      }
    }
    viewer = {
      principal_arn = aws_iam_role.access["viewer"].arn

      policy_associations = {
        view = {
          policy_arn   = "${local.eks_access_policy}/AmazonEKSViewPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }
  }

  enabled_log_types = ["api", "audit", "authenticator"]

  cloudwatch_log_group_retention_in_days = 7

  kms_key_deletion_window_in_days = 7

  addons = {
    vpc-cni = {
      before_compute = true
      # Turn on the VPC CNI network policy agent: without it, NetworkPolicies are
      # accepted by the API server but silently NOT enforced.
      configuration_values = jsonencode({ enableNetworkPolicy = "true" })
    }
    eks-pod-identity-agent = {
      before_compute = true
    }
    kube-proxy = {}
    coredns    = {}
  }

  eks_managed_node_groups = {
    default = {
      ami_type       = "AL2023_x86_64_STANDARD"
      capacity_type  = "SPOT"
      instance_types = ["t3.large", "t3a.large", "m5.large", "m6i.large"]

      min_size     = 1
      max_size     = 3
      desired_size = 2
    }
  }
}
