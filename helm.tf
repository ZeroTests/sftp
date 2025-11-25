terraform {
  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.12"
    }
  }
}

provider "helm" {
  kubernetes {
    host                   = data.aws_eks_cluster.cluster.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster.certificate_authority[0].data)
    token                  = data.aws_eks_cluster_auth.cluster.token
  }
}

# Create namespace first
resource "kubernetes_namespace" "sftp" {
  metadata {
    name = var.sftp_namespace
    labels = {
      name        = var.sftp_namespace
      environment = var.eks_cluster_name
    }
  }
}

# Helm Release for SFTP Server
resource "helm_release" "sftp_server" {
  name       = "sftp-server"
  namespace  = kubernetes_namespace.sftp.metadata[0].name
  chart      = "${path.module}/helm/sftp-server"
  
  # Wait for resources to be ready
  wait          = true
  wait_for_jobs = true
  timeout       = 600

  # Values
  values = [
    yamlencode({
      replicaCount = var.sftp_replicas

      # Service Account with IRSA
      serviceAccount = {
        create = true
        name   = "sftp-sa"
        annotations = {
          "eks.amazonaws.com/role-arn" = aws_iam_role.sftp_pod_role.arn
        }
      }

      # S3 Configuration
      s3 = {
        bucketName = aws_s3_bucket.sftp_storage.id
        region     = var.aws_region
        mountPoint = "/mnt/s3"
      }

      # SFTP Users
      users = [
        for user in var.sftp_users : {
          username  = user.username
          password  = user.password
          publicKey = user.public_key
        }
      ]

      # SSH Keys (for users with public keys)
      sshKeys = {
        for user in var.sftp_users :
        "${user.username}.pub" => user.public_key
        if user.public_key != null
      }

      # Internal Service
      service = {
        internal = {
          enabled = true
          type    = "ClusterIP"
          port    = 22
        }
        
        # External Service
        external = {
          enabled = true
          type    = "LoadBalancer"
          port    = 22
          annotations = {
            "service.beta.kubernetes.io/aws-load-balancer-type"   = "nlb"
            "service.beta.kubernetes.io/aws-load-balancer-scheme" = var.sftp_external_access_type
          }
          loadBalancerSourceRanges = var.sftp_allowed_cidrs
          externalTrafficPolicy    = "Local"
        }
      }

      # Resources
      resources = {
        requests = {
          cpu    = "100m"
          memory = "128Mi"
        }
        limits = {
          cpu    = "500m"
          memory = "512Mi"
        }
      }

      # Probes
      livenessProbe = {
        enabled = true
        tcpSocket = {
          port = 22
        }
        initialDelaySeconds = 30
        periodSeconds       = 10
      }

      readinessProbe = {
        enabled = true
        tcpSocket = {
          port = 22
        }
        initialDelaySeconds = 5
        periodSeconds       = 5
      }

      # SSHD Config
      sshdConfig = {
        enabled                 = true
        port                    = 22
        passwordAuthentication  = true
        pubkeyAuthentication    = true
        permitRootLogin         = false
        maxAuthTries            = 3
        maxSessions             = 10
      }

      # s3fs options
      s3fsOptions = {
        iamRole           = "auto"
        allowOther        = true
        useCache          = "/tmp/s3fs"
        ensureDiskfree    = 500
        umask             = "0022"
        uid               = 1001
        gid               = 1001
        multireqMax       = 5
        maxStatCacheSize  = 1000
        statCacheExpire   = 900
      }

      # Pod annotations
      podAnnotations = merge(
        {
          "prometheus.io/scrape" = "false"
        },
        var.tags
      )
    })
  ]

  depends_on = [
    aws_s3_bucket.sftp_storage,
    aws_iam_role.sftp_pod_role,
    kubernetes_namespace.sftp
  ]
}

# Data sources to get service endpoints after deployment
data "kubernetes_service" "sftp_internal" {
  metadata {
    name      = "${helm_release.sftp_server.name}-internal"
    namespace = helm_release.sftp_server.namespace
  }
  
  depends_on = [helm_release.sftp_server]
}

data "kubernetes_service" "sftp_external" {
  metadata {
    name      = "${helm_release.sftp_server.name}-external"
    namespace = helm_release.sftp_server.namespace
  }
  
  depends_on = [helm_release.sftp_server]
}