terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.59"
    }
    helm = {
      source  = "hashicorp/helm"
      version = ">= 2.17, < 3.0"
    }
  }
}
