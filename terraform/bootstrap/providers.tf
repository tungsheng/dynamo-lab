# terraform/bootstrap/providers.tf

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      "app.kubernetes.io/part-of" = "dynamo-lab"
      "project"                   = var.project
      "managed-by"                = "terraform"
      "terraform-root"            = "bootstrap"
    }
  }
}
