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

# Define EC2 worker nodes instance type
variable "instance_type" {
  description = "Instance type for EKS EC2 worker nodes"
  type = string
  default = "t3.small"
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
    Name = "${var.cluster_name}-Internet-Gateway"
  }
}

# Create EIP to be used with NAT Gateway
resource "aws_eip" "nat_eip" {
  domain = "vpc"      # EIP will be used for a VPC.

  tags = {
    Name = "${var.cluster_name}-NAT-EIP"
  }
}

# Create NAT Gateway
# Allows worker nodes to access Internet
# It's assigned to the first public subnet
resource "aws_nat_gateway" "eks_nat_gateway" {
  allocation_id = aws_eip.nat_eip.id        # Links to EIP
  subnet_id = aws_subnet.public_subnets[0].id

  tags = {
    Name = "${var.cluster_name}-NAT"
  }
}

# Create a route table for the public subnets
# Points to Internet Gateway
resource "aws_route_table" "public_subnets_route_table" {
  vpc_id = aws_vpc.eks-vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.eks_internet_gateway.id
  }

  tags = {
    Name = "${var.cluster_name}-public-subnets-route-table"
  }
}

# Create a route table for the private subnets
resource "aws_route_table" "private_subnets_route_table" {
  vpc_id = aws_vpc.eks-vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.eks_nat_gateway.id
  }

  tags = {
    Name = "${var.cluster_name}-private-subnets-route-table"
  }
}

# Create route table associations
resource "aws_route_table_association" "public_subnets_route_table_association" {
  count = 3
  subnet_id = aws_subnet.public_subnets[count.index].id
  route_table_id = aws_route_table.public_subnets_route_table.id
}

resource "aws_route_table_association" "private_subnets_route_table_association" {
  count = 3
  subnet_id = aws_subnet.private_subnets[count.index].id
  route_table_id = aws_route_table.private_subnets_route_table.id
}

# Create EKS IAM role that will allow the EKS cluster do necessary operations in AWS
# The role by itself doesn't grant permissions until we use the IAM policy attachment to attach the AWS-managed
#   AmazonEKSClusterPolicy policy.
resource "aws_iam_role" "eks_cluster_iam_role" {
  name = "${var.cluster_name}-eks-cluster-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "eks.amazonaws.com"
      }
    }]
  })
}

# Create IAM role policy attachment that attaches the AWS-managed policy to the role created above
resource "aws_iam_role_policy_attachment" "eks_cluster_iam_role_attachment" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.eks_cluster_iam_role.name
}

# Create IAM role for the EC2 instances that will be the cluster nodes
resource "aws_iam_role" "eks_cluster_nodes_role" {
  name = "${var.cluster_name}-eks-cluster-nodes-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
  })
}

# Create IAM role policy attachment that attaches the AWS-managed policies to the role created above
resource "aws_iam_role_policy_attachment" "eks_worker_node_policy" {
  # Worker node policy allows nodes (EC2 instances) to interact with EKS control plane
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.eks_cluster_nodes_role.name
}
resource "aws_iam_role_policy_attachment" "eks_cni_policy" {
  # CNI policy allows the cluster nodes to manage network interfaces
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.eks_cluster_nodes_role.name
}
resource "aws_iam_role_policy_attachment" "eks_container_registry_policy" {
  # Allows access to Elastic Continer Registry (ECR)
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.eks_cluster_nodes_role.name
}

# Create EKS cluster
resource "aws_eks_cluster" "eks_cluster" {
  name     = var.cluster_name
  role_arn = aws_iam_role.eks_cluster_iam_role.arn
  version = "1.27"

  vpc_config {
    subnet_ids = concat(aws_subnet.private_subnets[*].id, aws_subnet.public_subnets[*].id)
    endpoint_public_access = true
    endpoint_private_access = true
  }

  depends_on = [
  aws_iam_role_policy_attachment.eks_cluster_iam_role_attachment]
}

# Create EKS nodes group
resource "aws_eks_node_group" "eks_node_group" {
  cluster_name  = aws_eks_cluster.eks_cluster.name
  node_group_name = "${var.cluster_name}-eks-node-group"
  node_role_arn = aws_iam_role.eks_cluster_nodes_role.arn
  subnet_ids = aws_subnet.private_subnets[*].id

  scaling_config {
    desired_size = 4
    max_size     = 10
    min_size     = 4
  }

  instance_types = [var.instance_type]

  depends_on = [
    aws_iam_role_policy_attachment.eks_worker_node_policy,
    aws_iam_role_policy_attachment.eks_cni_policy,
    aws_iam_role_policy_attachment.eks_container_registry_policy
  ]
}

# Outputs
output "cluster_endpoint" {
  value = aws_eks_cluster.eks_cluster.endpoint
}

output "cluster_name" {
  value = aws_eks_cluster.eks_cluster.name
}

output "cluster_certificate_authority" {
  value = aws_eks_cluster.eks_cluster.certificate_authority[0].data
}