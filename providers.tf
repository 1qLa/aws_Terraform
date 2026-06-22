# AWSプロバイダーの設定
terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
        source  = "hashicorp/aws"
        version = "~> 5.0"
    }
  }

  // Terraformの状態管理をS3で行う設定
  backend "s3" {
    bucket = "kane-app-bucket-2240040"         # バケット名
    key    = "terraform.tfstate" # S3内に保存するファイル名
    region = "ap-northeast-1"

    profile = "dev" # AWS CLIで設定したプロファイルを指定
  }
}

provider "aws" {
  region  = "ap-northeast-1"
  profile = "dev" # AWS CLIで設定したプロファイルを指定
}