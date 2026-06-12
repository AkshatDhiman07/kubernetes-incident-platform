provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "incident-platform"
      Environment = "dev"
      ManagedBy   = "terraform"
      Owner       = "akshat"
    }
  }
}
