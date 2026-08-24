provider "aws" {
  region = var.region

  default_tags {
    tags = {
      project   = "alchemiscale"
      managedby = "opentofu"
      cluster   = "prod"
    }
  }
}

# Route53 health check metrics are only published in us-east-1, so their alarms
# have to be created there regardless of where the cluster runs.
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

  default_tags {
    tags = {
      project   = "alchemiscale"
      managedby = "opentofu"
      cluster   = "prod"
    }
  }
}

# The Kubernetes and Helm providers authenticate the same way `kubectl` does,
# by shelling out for an EKS token. Applying this module therefore requires an
# access entry on the cluster (operators have one; see `admin_principal_arns`).
provider "kubernetes" {
  host                   = module.cluster.cluster_endpoint
  cluster_ca_certificate = base64decode(module.cluster.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.cluster.cluster_name, "--region", var.region]
  }
}

provider "helm" {
  kubernetes {
    host                   = module.cluster.cluster_endpoint
    cluster_ca_certificate = base64decode(module.cluster.cluster_certificate_authority_data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.cluster.cluster_name, "--region", var.region]
    }
  }
}
