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