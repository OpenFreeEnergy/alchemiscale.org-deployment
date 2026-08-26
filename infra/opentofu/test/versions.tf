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
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.35"
    }
  }

  # Separate state from prod, so this whole stack can be destroyed and re-applied
  # by the reaper without prod state ever being opened.
  #
  #   tofu init -backend-config=backend.hcl
  backend "s3" {
    key          = "test/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }

  encryption {
    key_provider "aws_kms" "state" {
      kms_key_id = "alias/alchemiscale-tofu-state"
      region     = "us-east-1"
      key_spec   = "AES_256"
    }

    method "aes_gcm" "state" {
      keys = key_provider.aws_kms.state
    }

    state {
      method = method.aes_gcm.state
    }

    plan {
      method = method.aes_gcm.state
    }
  }
}
