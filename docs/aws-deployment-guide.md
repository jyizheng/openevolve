# OpenEvolve AWS Batch Deployment Guide

This guide walks through deploying OpenEvolve on AWS Batch with Spot instances, S3 storage, Secrets Manager, CloudWatch monitoring, and per-user IAM access.

## Prerequisites

- AWS CLI v2 installed and configured with admin credentials
- Terraform >= 1.5 installed
- Docker installed and running
- Git installed
- A Gemini API key (from [Google AI Studio](https://aistudio.google.com))

---

## Step 1: Clone the Repository and Check Out the Branch

```bash
git clone https://github.com/jyizheng/openevolve.git
cd openevolve
git checkout aws-deployment
```

---

## Step 2: Configure AWS CLI (Admin Credentials)

You need admin-level AWS credentials to provision resources.

```bash
aws configure
# AWS Access Key ID:     <your-admin-access-key>
# AWS Secret Access Key: <your-admin-secret-key>
# Default region name:   us-east-1
# Default output format: json
```

Verify:
```bash
aws sts get-caller-identity
# Should show your admin user/role ARN
```

---

## Step 3: Bootstrap the Terraform S3 State Backend

Terraform needs an S3 bucket + DynamoDB table to store state remotely. Run this **once** before any `terraform init`.

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# Create S3 bucket for Terraform state
aws s3api create-bucket \
  --bucket "openevolve-tf-state-${ACCOUNT_ID}" \
  --region us-east-1

# Enable versioning (protects state from accidental deletion)
aws s3api put-bucket-versioning \
  --bucket "openevolve-tf-state-${ACCOUNT_ID}" \
  --versioning-configuration Status=Enabled

# Create DynamoDB table for state locking
aws dynamodb create-table \
  --table-name openevolve-tf-locks \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region us-east-1
```

---

## Step 4: Configure Terraform Variables

```bash
cd infra
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars`:
```hcl
aws_region   = "us-east-1"
environment  = "prod"

# IAM usernames to create (one per team member)
iam_users = ["alice", "bob", "ron"]

# Email for cost/error alerts
alert_email = "your-email@example.com"

# Monthly budget in USD - alerts at 80% and 100%
monthly_budget_usd = 200

# Max vCPUs across both Spot + On-Demand compute environments
max_vcpus = 256

# EC2 instance types (Batch picks the cheapest available Spot)
instance_types = ["m5.2xlarge", "m5.4xlarge", "c5.2xlarge", "c5.4xlarge", "r5.2xlarge"]
```

Edit `infra/main.tf` to update the backend bucket name:
```hcl
terraform {
  backend "s3" {
    bucket         = "openevolve-tf-state-<your-account-id>"
    key            = "prod/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "openevolve-tf-locks"
    encrypt        = true
  }
}
```

---

## Step 5: Initialize and Apply Terraform

```bash
cd infra

# Initialize - downloads providers, connects to S3 backend
terraform init

# Preview changes (no resources created yet)
terraform plan -out=plan.tfplan

# Apply - creates all AWS resources (~5-10 minutes)
terraform apply plan.tfplan
```

When complete, capture the outputs:
```bash
terraform output -json
```

Key outputs to note:
- `ecr_repository_url` - Docker image registry URL
- `cli_config` - env vars for the `openevolve-aws` CLI
- `gemini_secret_arn` - Secrets Manager ARN for the API key
- `user_credentials` - (sensitive) IAM access keys per user

---

## Step 6: Store the Gemini API Key in Secrets Manager

Terraform creates the secret with a placeholder. Replace it with your real key:

```bash
GEMINI_SECRET_ARN=$(cd infra && terraform output -raw gemini_secret_arn)

aws secretsmanager put-secret-value \
  --secret-id "${GEMINI_SECRET_ARN}" \
  --secret-string '{"GEMINI_API_KEY":"AIza...your-real-key..."}' \
  --region us-east-1
```

---

## Step 7: Build and Push the Docker Image to ECR

```bash
cd ..  # back to repo root

ECR_URL=$(cd infra && terraform output -raw ecr_repository_url)
REGION=us-east-1

# Log Docker into ECR
aws ecr get-login-password --region "${REGION}" \
  | docker login --username AWS --password-stdin "${ECR_URL}"

# Build the image (uses Dockerfile.aws)
docker build -f Dockerfile.aws -t openevolve-aws .

# Tag and push
docker tag openevolve-aws:latest "${ECR_URL}:latest"
docker push "${ECR_URL}:latest"
```

This step takes ~5-10 minutes on the first build (downloads Rust toolchain, AWS CLI v2, etc.).

---

## Step 8: Set Up the CLI Environment

Add these exports to your `~/.bashrc` or `~/.zshrc`. Get the values from `terraform output -json cli_config`:

```bash
export OPENEVOLVE_INPUT_BUCKET="openevolve-prod-inputs-xxxx"
export OPENEVOLVE_OUTPUT_BUCKET="openevolve-prod-outputs-xxxx"
export OPENEVOLVE_JOB_QUEUE="openevolve-prod-queue"
export OPENEVOLVE_JOB_DEFINITION="openevolve-prod-job"
export AWS_DEFAULT_REGION="us-east-1"
```

Make the CLI script executable and available system-wide:
```bash
chmod +x scripts/openevolve-aws
sudo ln -s "$(pwd)/scripts/openevolve-aws" /usr/local/bin/openevolve-aws
```

---

## Step 9: Configure Per-User AWS Credentials

Each IAM user gets their own scoped access key. Retrieve them from Terraform:
```bash
cd infra
terraform output -json user_credentials
# Returns access_key_id and secret_access_key per user (sensitive)
```

Each team member runs:
```bash
aws configure --profile openevolve
# AWS Access Key ID:     <their-access-key>
# AWS Secret Access Key: <their-secret-key>
# Default region:        us-east-1
```

Then prefix commands with `AWS_PROFILE=openevolve` or set it as default:
```bash
export AWS_PROFILE=openevolve
```

---

## Step 10: Submit Your First Job

```bash
# Create a simple test program
cat > /tmp/initial_program.py << 'EOF'
# EVOLVE-BLOCK-START
def solve(x):
    return x * x
# EVOLVE-BLOCK-END
EOF

# Create a simple evaluator
cat > /tmp/evaluator.py << 'EOF'
def evaluate(program_path):
    import importlib.util
    spec = importlib.util.spec_from_file_location("program", program_path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    score = -abs(mod.solve(3) - 9)  # perfect score = 0
    return {"score": score}
EOF

# Submit the job
openevolve-aws submit \
  --program   /tmp/initial_program.py \
  --evaluator /tmp/evaluator.py \
  --iterations 100
```

Output looks like:
```
Job short ID : a1b2c3d4
User         : alice
Iterations   : 100

Uploading inputs to s3://openevolve-prod-inputs-xxxx/users/alice/a1b2c3d4/input...
Submitting to Batch...

  Batch job ID : abc12345-6789-abcd-ef01-234567890abc
  Status       : SUBMITTED
  Results will appear at: s3://openevolve-prod-outputs-xxxx/users/alice/a1b2c3d4/output

  Track progress:
    openevolve-aws status  abc12345-6789-abcd-ef01-234567890abc
    openevolve-aws logs    abc12345-6789-abcd-ef01-234567890abc --follow
    openevolve-aws results abc12345-6789-abcd-ef01-234567890abc
```

---

## Step 11: Monitor the Job

```bash
JOB_ID="abc12345-6789-abcd-ef01-234567890abc"

# Check job status and metadata
openevolve-aws status ${JOB_ID}

# Stream logs in real time
openevolve-aws logs ${JOB_ID} --follow

# List all jobs by status
openevolve-aws list RUNNING
openevolve-aws list SUCCEEDED
openevolve-aws list FAILED
```

CloudWatch dashboard is also available in the AWS console under **CloudWatch > Dashboards > openevolve-prod**.

---

## Step 12: Download Results

```bash
JOB_ID="abc12345-6789-abcd-ef01-234567890abc"

# Download results (excludes checkpoints by default)
openevolve-aws results ${JOB_ID} --output ./my-results

# Contents of ./my-results:
#   best_program.py         - the highest-scoring evolved program
#   evolution_summary.json  - scores, metrics, iteration counts
#   logs/                   - per-iteration logs

# To also download checkpoints (for resuming or inspection):
openevolve-aws results ${JOB_ID} --output ./my-results
aws s3 sync \
  "s3://${OPENEVOLVE_OUTPUT_BUCKET}/users/<username>/<short-id>/output/checkpoints/" \
  "./my-results/checkpoints/"
```

---

## Step 13: Spot Interruption and Automatic Resume

OpenEvolve is designed to survive AWS Spot interruptions with **no manual action**:

1. AWS sends `SIGTERM` 2 minutes before the Spot instance is reclaimed
2. The entrypoint catches `SIGTERM`, asks OpenEvolve to checkpoint, and waits up to 90 seconds
3. The checkpoint is synced to S3 under `output/checkpoints/checkpoint_N/`
4. AWS Batch automatically retries the job (up to 3 attempts per job definition)
5. On retry, the entrypoint downloads the latest checkpoint from S3 and passes `--checkpoint` to OpenEvolve
6. Evolution resumes from where it left off

Additionally, a background sync loop runs every 5 minutes, so even a hard kill loses at most 5 minutes of work.

---

## Step 14: Cancel a Job

```bash
openevolve-aws cancel ${JOB_ID}
```

---

## Step 15: Destroy All Resources (Cleanup)

When you no longer need the infrastructure:

```bash
cd infra
terraform destroy
```

> **Warning:** This deletes all AWS resources including S3 buckets, job results, IAM users, ECR images, and the VPC. Make sure to download any results you want to keep first.

---

## Architecture Overview

```
User
 |
 | openevolve-aws CLI (scripts/openevolve-aws)
 |
 |--> S3 Input Bucket
 |       initial_program.py
 |       evaluator.py
 |       config.yaml (optional)
 |
 |--> AWS Batch Job Queue
         |
         +--> Spot Compute Environment (SPOT_CAPACITY_OPTIMIZED)
         |       EC2: m5/c5/r5 instances
         |       Falls back to On-Demand if no Spot available
         |
         +--> Docker Container (openevolve:latest from ECR)
                 |
                 |--> Downloads inputs from S3
                 |--> Resumes from checkpoint (if Spot retry)
                 |--> Runs OpenEvolve evolution loop
                 |       LLM: Gemini (via OpenAI-compatible API)
                 |       API key: injected from Secrets Manager
                 |--> Syncs checkpoints to S3 every 5 min (background)
                 |--> SIGTERM handler: checkpoint + sync before exit
                 |--> Uploads final results to S3 Output Bucket
                 |
                 +--> CloudWatch Logs (/aws/batch/openevolve)
                 +--> CloudWatch Metrics (OpenEvolve namespace)
                 +--> SNS Alerts (budget, job failures)
```

---

## IAM Access Model

Each team member gets a scoped IAM user that can only:
- Read/write S3 objects under `users/<their-username>/`
- Submit jobs to the shared Batch queue
- View job status and logs
- Cancel their own jobs

They cannot access other users' data or modify infrastructure.

---

## Cost Optimization Tips

- **Spot instances** are used by default (~60-80% cheaper than On-Demand)
- **Checkpointing** ensures Spot interruptions don't waste work
- **S3 lifecycle rules** automatically tier old outputs to cheaper storage (STANDARD_IA after 30 days)
- Set `--iterations` conservatively for exploration; scale up once the evaluator is validated
- Use the **AWS Budget** alert (configured in `terraform.tfvars`) to catch cost spikes early

---

## Troubleshooting

### Job fails immediately
```bash
openevolve-aws logs ${JOB_ID}
# Look for "ERROR" lines near the top of the output
```

Common causes:
- `GEMINI_API_KEY` not set in Secrets Manager (Step 6)
- `initial_program.py` or `evaluator.py` not uploaded correctly
- Docker image not pushed to ECR (Step 7)

### Job stuck in RUNNABLE state
The Spot market may be constrained. Check:
```bash
aws batch describe-jobs --jobs ${JOB_ID} --query 'jobs[0].statusReason'
```
Add more instance types to `instance_types` in `terraform.tfvars` and re-apply.

### Cannot submit jobs (access denied)
Verify your AWS credentials match an IAM user created by Terraform:
```bash
aws sts get-caller-identity
terraform output -json user_credentials  # run as admin
```

### Results not appearing in S3
The background sync runs every 5 minutes; wait and check again. For completed jobs, sync is immediate. Verify:
```bash
aws s3 ls s3://${OPENEVOLVE_OUTPUT_BUCKET}/users/<username>/
```
