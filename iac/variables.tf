variable "aws_region" {
  description = "AWS Region. Floci ignores this, but it is needed by the provider."
  type        = string
  default     = "us-east-1"
}

variable "floci_endpoint" {
  description = "Endpoint for the floci emulator."
  type        = string
  default     = "http://localhost:4566"
}

variable "project_name" {
  description = "Name-Prefix for all created resources."
  type        = string
  default     = "floci-fastapi-demo"
}

variable "vpc_cidr" {
  description = "CIDR-Block of the VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "CIDR-Blocks of the two public subnets (one per AZ)."
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "availability_zones" {
  description = "Availability Zones for the subnets."
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}