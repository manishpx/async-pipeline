variable "region" {
  type    = string
  default = "eu-north-1" # Stockholm
}

variable "dr_region" {
  type    = string
  default = "eu-central-1" # Frankfurt — EU-only DR
}

variable "env" {
  type    = string
  default = "dev"
}

variable "ecr_repo_url" {
  description = "ECR repo URL hosting the scrub/enrich/load images (e.g. 123456789012.dkr.ecr.eu-north-1.amazonaws.com/csv)"
  type        = string
  default    = "public.ecr.aws/docker/library/nginx:latest" # Placeholder, replace with your ECR repo URL
}

variable "image_tag" {
  type    = string
  default = "latest"
}

variable "db_username" {
  type    = string
  default = "csvapp"
}

variable "db_name" {
  type    = string
  default = "customers"
}

variable "notify_email" {
  description = "Ops alerts email"
  type        = string
  default     = "abc5057@gmail.com"
}