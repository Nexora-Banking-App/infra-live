data "terraform_remote_state" "shared" {
  backend = "s3"
  config = {
    bucket = "nexora-tf-state-ahmed"
    key    = "prod-shared/terraform.tfstate"
    region = "us-east-1"
  }
}