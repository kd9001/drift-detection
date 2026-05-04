terraform {
  backend "s3" {
    bucket = "drift-detection-tfstate-deepak"
    key    = "drift-demo/terraform.tfstate"
    region = "us-east-1"
  }
}