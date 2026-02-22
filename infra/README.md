# OpenEvolve AWS Infrastructure

Terraform-managed AWS deployment for OpenEvolve, built around AWS Batch for
long-running, cost-optimised evolution jobs.

## Architecture at a glance

```
Users (IAM)
    │
    ▼  openevolve-aws submit
scripts/openevolve-aws ──► AWS Batch Job Queue (Spot-first)
                                │
                                ▼
                         EC2 Spot instances (c5.2/4xlarge)
                         running Docker container
                                │
                    ┌───────────┴────────────┐
                    ▼                        ▼
             S3 input bucket          S3 output bucket
             (programs, configs)      (checkpoints, results)
                                           │
                                     CloudWatch Logs
                                     CloudWatch Metrics
                                     SNS → email alerts
```

**Core service choices:**
- **AWS Batch** — purpose-built for batch compute; scales to zero, natively supports
  Spot with On-Demand fallback, has job queuing and retry built in.
- **Spot-first** — OpenEvolve's checkpoint/resume support means Spot interruptions
  just trigger a retry from the last saved checkpoint (~70-90% cost saving).
- **S3** for all persistent state — inputs, outputs, checkpoints. Lifecycle policies
  tier old data to IA then Glacier automatically.

## Directory structure

```
infra/
├── main.tf                    # Root module — wires all modules together
├── variables.tf
├── outputs.tf
├── terraform.tfvars.example   # Copy to terraform.tfvars and fill in
└── modules/
    ├── vpc/        # VPC, private subnets, single NAT Gateway
    ├── ecr/        # Container registry, lifecycle policy
    ├── s3/         # Input + output buckets, encryption, lifecycle
    ├── secrets/    # Secrets Manager entry for GEMINI_API_KEY
    ├── iam/        # Batch service role, instance role, job role, Spot fleet role
    ├── batch/      # Compute environments, job queue, job definition
    ├── monitoring/ # CloudWatch log group, dashboard, SNS, AWS Budgets
    └── users/      # IAM users + scoped policies for team members
```

## First-time deployment

### 1. Prerequisites

```bash
# Install Terraform >= 1.5
brew install terraform   # or https://developer.hashicorp.com/terraform/install

# AWS credentials configured
aws configure   # or export AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY
```

### 2. Bootstrap remote state (optional but recommended)

Terraform needs somewhere to store its state file. Before enabling the S3 backend:

```bash
# Create the state bucket (replace <account-id>)
aws s3api create-bucket \
  --bucket openevolve-terraform-state-<account-id> \
  --region us-east-1

aws s3api put-bucket-versioning \
  --bucket openevolve-terraform-state-<account-id> \
  --versioning-configuration Status=Enabled

# Create the DynamoDB table for state locking
aws dynamodb create-table \
  --table-name openevolve-terraform-locks \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region us-east-1
```

Then uncomment the `backend "s3"` block in [main.tf](main.tf) and run
`terraform init -migrate-state`.

### 3. Configure variables

```bash
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars — at minimum set alert_email and iam_users
```

### 4. Deploy

```bash
cd infra/
terraform init
terraform plan    # Review what will be created
terraform apply
```

### 5. Set the Gemini API key

After apply, the Secrets Manager secret exists but contains a placeholder.
Set the real key:

```bash
# Get the secret ARN from Terraform output
SECRET_ARN=$(terraform output -raw gemini_secret_arn)

aws secretsmanager put-secret-value \
  --secret-id "${SECRET_ARN}" \
  --secret-string "your-actual-gemini-api-key"
```

### 6. Build and push the Docker image

```bash
# Get the ECR URL from Terraform output
ECR_URL=$(terraform output -raw ecr_repository_url)
REGION=us-east-1

# Authenticate Docker to ECR
aws ecr get-login-password --region ${REGION} \
  | docker login --username AWS --password-stdin ${ECR_URL}

# Build and push (run from the repo root, not infra/)
cd ..
docker build -f Dockerfile.aws -t ${ECR_URL}:latest .
docker push ${ECR_URL}:latest
```

### 7. Retrieve user credentials

```bash
terraform output -json user_credentials
```

Distribute the `access_key_id` and `secret_access_key` to each team member
securely (e.g., via a secrets vault, not email).

---

## Submitting jobs

Each user needs the CLI configured:

```bash
# Get config from Terraform (run as admin)
terraform output -json cli_config

# Set these in ~/.bashrc or ~/.zshrc
export OPENEVOLVE_INPUT_BUCKET=openevolve-prod-inputs-xxxx
export OPENEVOLVE_OUTPUT_BUCKET=openevolve-prod-outputs-xxxx
export OPENEVOLVE_JOB_QUEUE=openevolve-prod-queue
export OPENEVOLVE_JOB_DEFINITION=openevolve-prod-job
export AWS_DEFAULT_REGION=us-east-1

# Configure AWS credentials (access key from step 7 above)
aws configure
```

Then submit a job:

```bash
../scripts/openevolve-aws submit \
  --program  my_program.py  \
  --evaluator evaluator.py  \
  --config   config.yaml    \
  --iterations 500
```

Other commands:

```bash
openevolve-aws status  <job-id>
openevolve-aws logs    <job-id> --follow
openevolve-aws results <job-id> --output ./my-run
openevolve-aws list    RUNNING
openevolve-aws cancel  <job-id>
```

---

## Cost model

| Component | Notes | Typical cost |
|---|---|---|
| EC2 Spot (c5.2xlarge) | ~$0.08–0.12/hr vs $0.34/hr On-Demand | $0.16–0.50 per 2-4hr job |
| Gemini Flash API | Dominant cost — billed outside AWS | $5–20 per 1000 iterations |
| S3 | Inputs + checkpoints + results | ~$0.05/job |
| NAT Gateway | Outbound LLM API traffic (small JSON) | ~$0.05/job |
| CloudWatch Logs | 30-day retention | ~$0.01/job |

**AWS budget alert** fires at 80% of the configured monthly limit (`monthly_budget_usd`).
The Gemini API cost is **not** captured by this budget — monitor it in the Google
AI Studio console separately.

---

## Spot interruption handling

OpenEvolve has built-in checkpoint/resume. When a Spot instance is reclaimed:

1. AWS sends SIGTERM to the container (2-minute warning).
2. `docker-entrypoint.sh` catches SIGTERM, asks OpenEvolve to exit cleanly,
   and syncs the output directory to S3.
3. Batch retries the job (up to 3 attempts) with `AWS_BATCH_JOB_ATTEMPT=1`.
4. On retry, the entrypoint finds the latest checkpoint in S3, downloads it,
   and passes `--checkpoint` to OpenEvolve.

Net result: at most ~10 iterations lost (the default `checkpoint_interval`).

---

## Adding a new user

Edit `terraform.tfvars`, add the username to `iam_users`, then:

```bash
terraform apply
terraform output -json user_credentials | jq '.["new-username"]'
```

## Updating the Docker image

```bash
docker build -f Dockerfile.aws -t ${ECR_URL}:latest . && docker push ${ECR_URL}:latest
```

New jobs immediately use `:latest`. In-flight jobs are not affected.
If you need a stable tag, push to a versioned tag and update the job definition.

## Tearing down

```bash
terraform destroy
```

S3 buckets with objects in them will fail to destroy. Empty them first:

```bash
aws s3 rm s3://${INPUT_BUCKET}  --recursive
aws s3 rm s3://${OUTPUT_BUCKET} --recursive
terraform destroy
```
