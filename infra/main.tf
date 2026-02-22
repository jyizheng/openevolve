terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
  }

  # Bootstrap: before uncommenting this block, create the S3 bucket and DynamoDB
  # table manually (or with a separate one-time script), then run:
  #   terraform init -migrate-state
  #
  backend "s3" {
    bucket         = "openevolve-tf-state-539042711111-use2"
    key            = "prod/terraform.tfstate"
    region         = "us-east-2"
    dynamodb_table = "openevolve-tf-locks"
    encrypt        = true
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "openevolve"
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  prefix     = "openevolve-${var.environment}"
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.name
}

# ── Monitoring first: Batch needs the log group name ─────────────────────────
module "monitoring" {
  source = "./modules/monitoring"

  prefix           = local.prefix
  region           = local.region
  account_id       = local.account_id
  alert_email      = var.alert_email
  monthly_budget   = var.monthly_budget_usd
}

module "vpc" {
  source = "./modules/vpc"

  prefix = local.prefix
}

module "ecr" {
  source = "./modules/ecr"

  prefix = local.prefix
}

module "s3" {
  source = "./modules/s3"

  prefix = local.prefix
}

module "secrets" {
  source = "./modules/secrets"

  prefix = local.prefix
}

module "iam" {
  source = "./modules/iam"

  prefix            = local.prefix
  account_id        = local.account_id
  region            = local.region
  input_bucket_arn  = module.s3.input_bucket_arn
  output_bucket_arn = module.s3.output_bucket_arn
  gemini_secret_arn = module.secrets.gemini_secret_arn
  log_group_arn     = module.monitoring.log_group_arn
}

module "batch" {
  source = "./modules/batch"

  prefix                     = local.prefix
  region                     = local.region
  vpc_id                     = module.vpc.vpc_id
  private_subnet_ids         = module.vpc.private_subnet_ids
  ecr_repository_url         = module.ecr.repository_url
  batch_service_role_arn     = module.iam.batch_service_role_arn
  batch_instance_profile_arn = module.iam.batch_instance_profile_arn
  batch_job_role_arn         = module.iam.batch_job_role_arn
  spot_fleet_role_arn        = module.iam.spot_fleet_role_arn
  ecs_execution_role_arn     = module.iam.ecs_execution_role_arn
  log_group_name             = module.monitoring.log_group_name
  gemini_secret_arn          = module.secrets.gemini_secret_arn
  input_bucket_name          = module.s3.input_bucket_name
  output_bucket_name         = module.s3.output_bucket_name
  max_vcpus                  = var.max_vcpus
  instance_types             = var.instance_types
}

module "users" {
  source = "./modules/users"

  prefix             = local.prefix
  usernames          = var.iam_users
  input_bucket_arn   = module.s3.input_bucket_arn
  output_bucket_arn  = module.s3.output_bucket_arn
  input_bucket_name  = module.s3.input_bucket_name
  output_bucket_name = module.s3.output_bucket_name
  job_queue_arn      = module.batch.job_queue_arn
  job_definition_arn = module.batch.job_definition_arn
  log_group_arn      = module.monitoring.log_group_arn
}

# Wire batch alarm into monitoring after batch is created
resource "aws_cloudwatch_metric_alarm" "job_failures" {
  alarm_name          = "${local.prefix}-job-failures"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "FailedJobCount"
  namespace           = "AWS/Batch"
  period              = 300
  statistic           = "Sum"
  threshold           = 3
  alarm_description   = "More than 3 Batch jobs failed in the last 5 minutes"
  alarm_actions       = [module.monitoring.alert_topic_arn]
  treat_missing_data  = "notBreaching"

  dimensions = {
    JobQueue = module.batch.job_queue_name
  }
}
