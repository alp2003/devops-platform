terraform {
  required_version = ">= 1.17"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.71"
    }
  }
  backend "s3" {
    bucket       = "tfstate-351323458847"
    key          = "devops-platform/registry.tfstate"
    region       = "us-east-1"
    use_lockfile = true
  }
}

provider "aws" {
  region = "us-east-1"
  default_tags {
    tags = {
      Project   = "devops-platform"
      ManagedBy = "terraform"
    }
  }
}
