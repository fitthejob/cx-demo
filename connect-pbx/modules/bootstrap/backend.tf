terraform {
  backend "s3" {
    bucket         = "acme-tfstate-017677777575"
    key            = "bootstrap/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    kms_key_id     = "arn:aws:kms:us-east-1:017677777575:key/bdd478e8-d10e-4ce4-b1d1-9925a39e18e4"
    dynamodb_table = "acme-tfstate-lock"
  }
}
