terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"      # registry.terraform.io/hashicorp
      version = "5.78.0"
    }
  }

  required_version = ">= 1.2.0"     # Refers to Terraform CLI version
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

# Define cluster name
variable "cluster_name" {
  description = "Kubernetes cluster name"
  type = string
  default = "eks"
}

# Define VPC Name
variable "vpc_name" {
  description = "Name of VPC"
  type = string
}

# Define subnet name prefix
variable "subnet_prefix" {
  description = "Prefix for subnet name. Number will be appended."
  type = string
  default = "subnet"
}

# Get availability zones
data "aws_availability_zones" "available_zones" {}

# Create VPC
resource "aws_vpc" "eks-vpc" {
  cidr_block = "192.168.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support = true
  tags = {
    Name = var.vpc_name
  }
}

# Create subnets with public access
resource "aws_subnet" "public_subnets" {
  vpc_id = aws_vpc.eks-vpc.id
  count = 3
  cidr_block = "192.168.${count.index + 1}.0/24"
  availability_zone = data.aws_availability_zones.available_zones.names[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.subnet_prefix}-${count.index + 1}-public"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"      # Used by AWS to identify this subnet for use by cluster
    "kubernetes.io/role/elb" = "1"    # Tels AWS Load Balancer Controller to use this subnet for external-facing LBs
  }
}

# Create private subnets
resource "aws_subnet" "private_subnets" {
  vpc_id = aws_vpc.eks-vpc.id
  count = 3
  cidr_block = "192.168.${count.index + 4}.0/24"
  availability_zone = data.aws_availability_zones.available_zones.names[count.index]

  tags = {
    Name = "${var.subnet_prefix}-${count.index + 1}"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "kubernetes.io/role/internal-elb" = "1"
  }
}

# Create Internet Gateway
resource "aws_internet_gateway" "eks_internet_gateway" {
  vpc_id = aws_vpc.eks-vpc.id

  tags = {
    Name = "EKS-Internet-Gateway"
  }
}