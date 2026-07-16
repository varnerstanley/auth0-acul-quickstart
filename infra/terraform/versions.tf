terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.40"
    }
  }

  # ---------------------------------------------------------------------------
  # SAMPLE: state is local by default, which is fine for a solo experiment ONLY.
  #
  # Terraform state records your whole infrastructure and can contain sensitive
  # values in plain text. For anything shared or long-lived, use a remote
  # backend with encryption + locking, and never commit state to git.
  # ---------------------------------------------------------------------------
  # backend "s3" {
  #   bucket         = "your-tf-state-bucket"   # pre-existing, private, versioned
  #   key            = "acul/terraform.tfstate"
  #   region         = "us-east-1"
  #   encrypt        = true
  #   dynamodb_table = "your-tf-state-locks"    # state locking
  # }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = var.tags
  }
}
