terraform {
  backend "s3" {
    bucket         = "acme-tfstate-017677777575"
    key            = "bootstrap/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    kms_key_id     = "arn:aws:kms:us-east-1:017677777575:key/3ac999b1-4ea4-4a03-bceb-8340271c3de3"
    dynamodb_table = "acme-tfstate-lock"
  }
}
