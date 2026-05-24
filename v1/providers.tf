provider "aws" {
  region = var.region
  default_tags {
    tags = {
      Project     = "csv-pipeline"
      Environment = var.env
      ManagedBy   = "terraform"
      Owner       = "platform-team"
      DataClass   = "pii"
    }
  }
}

# Frankfurt provider — DR backup bucket only
provider "aws" {
  alias  = "dr"
  region = var.dr_region
  default_tags {
    tags = {
      Project     = "csv-pipeline"
      Environment = var.env
      ManagedBy   = "terraform"
      Purpose     = "dr-backup"
    }
  }
}