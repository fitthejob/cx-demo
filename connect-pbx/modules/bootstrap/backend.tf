terraform {
  backend "s3" {
    bucket       = "acme-tfstate-017677777575"
    key          = "bootstrap/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    kms_key_id   = "arn:aws:kms:us-east-1:017677777575:key/15a7f475-6aab-4d90-891c-8a2d76fc27ea"
    use_lockfile = true
  }
}
