terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.59"
    }
  }

  # No kubernetes or helm provider: this layer is applied before either cluster
  # exists, and must stay appliable when neither does.
  #
  # Partial configuration: the bucket name is account-specific and comes from
  # the bootstrap layer.
  #
  #   tofu init -backend-config=backend.hcl
  backend "s3" {
    key          = "identity/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }

  # client-side state encryption, on top of S3's at-rest encryption
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
