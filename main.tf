terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"      # registry.terraform.io/hashicorp
      version = "5.78.0"
    }

    required_version = ">= 1.2.0"   # Refers to Terraform CLI version
  }
}

# Create AWS Region variable
variable "aws_region" {
  description = "AWS region"
  type = string
  default = "us-east-1"
}

# Configure AWS provider
provider "aws" {
  region = var.aws_region
  profile = "default"
}

