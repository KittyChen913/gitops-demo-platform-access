terraform {
  required_version = ">= 1.11.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    linode = {
      source  = "linode/linode"
      version = "~> 4.1"
    }
  }
}

provider "aws" {
  region = local.deployment_config.aws.region
}

provider "linode" {}
