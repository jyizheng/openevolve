# OpenEvolve AWS Infrastructure — Full Lifecycle Plan

This document covers the full lifecycle of an OpenEvolve deployment beyond initial setup: resource allocation strategy, cost efficiency, scalability, monitoring, security, reliability, and operational excellence.

---

## 1. Resource Allocation

### Understanding the Workload

OpenEvolve jobs have a distinctive profile that shapes every resource decision:

- **CPU-bound evaluators**: Each iteration spawns worker processes that compile and run code. A 100-iteration job with 8 parallel workers saturates all vCPUs continuously.
- **External LLM calls**: Inference happens via Gemini API over HTTPS — no GPU needed, but workers frequently block on network I/O. This means CPU saturation is rarely 100%; there is headroom.
- **Memory**: The MAP-Elites database lives in RAM. At default settings it stays under 2 GB, but with large artifacts (compiled binaries, large datasets) it can grow. Rule of thumb: 2 GB baseline + 256 MB per parallel worker.
- **Storage I/O**: Mostly sequential checkpoint writes every few minutes. Disk is not a bottleneck.
- **Duration**: Jobs run for hours to days, not seconds. Startup latency (cold EC2 boot, Docker pull, S3 sync) of 2–3 minutes is negligible.

### Instance Family Selection

| Use Case | Recommended Family | Rationale |
|---|---|---|
| General evolution (default) | `m6i`, `m5` | Balanced CPU/memory; widest Spot availability |
| Compilation-heavy evaluators (Rust, C++) | `c6i`, `c5` | Higher CPU clock, better single-thread perf |
| Large in-memory databases / JVM evaluators | `r6i`, `r5` | 2:1 memory-to-CPU ratio |
| GPU inference (if self-hosting LLM in future) | `g4dn`, `g5` | Not needed today; plan for optionality |

**Never use burstable instances** (`t3`, `t4g`) — OpenEvolve runs at sustained CPU load and will immediately exhaust CPU credits, making performance unpredictable and more expensive than fixed instances.

### Sizing per Job

```
Default:   8 vCPU / 14 GB RAM  (1 job per m5.2xlarge or c5.2xlarge)
Large:    16 vCPU / 30 GB RAM  (higher parallelism, faster iteration wall-clock)
XLarge:   32 vCPU / 60 GB RAM  (for evaluators that benefit from many parallel workers)
```

The right size depends on the evaluator:
- If evaluation takes <1s per program: more vCPUs give linear speedup
- If evaluation is network-bound (API calls): extra vCPUs idle; use smaller instance
- If evaluation is memory-bound: scale memory first

### Compute Environment Strategy

Two compute environments in the job queue, in priority order:

```
Priority 1 — Spot (SPOT_CAPACITY_OPTIMIZED)
  min_vcpus = 0        (scale to zero when idle; critical for cost)
  max_vcpus = 256
  instance_types = [m6i.2xlarge, m6i.4xlarge, c6i.2xlarge, c6i.4xlarge,
                    m5.2xlarge, m5.4xlarge, c5.2xlarge, c5.4xlarge, r5.2xlarge]

Priority 2 — On-Demand (BEST_FIT_PROGRESSIVE)
  min_vcpus = 0
  max_vcpus = 64       (smaller cap; fallback only, not primary)
  instance_types = [m5.2xlarge, m5.4xlarge]
```

**Wide instance type pool is not optional** — it is the primary lever for Spot availability. A pool of 8–10 instance types in 2–3 sizes means Batch can always find capacity somewhere. Narrowing this to 1–2 types will cause jobs to queue for hours during Spot shortages.

---

## 2. Cost Efficiency

### Spot Economics

Spot instances cost 60–80% less than On-Demand. For OpenEvolve — a batch workload with native checkpoint/resume — Spot is the right default. The key risks and mitigations:

| Risk | Likelihood | Mitigation |
|---|---|---|
| Spot interruption mid-job | 5–15% per instance-hour | Checkpoint/resume (already implemented) |
| No Spot capacity available | Low with wide pool | On-Demand fallback queue |
| Interruption wastes compute | Low | Background S3 sync every 5 min limits loss to <5 min |

**Expected effective interruption waste**: With 5-minute sync intervals and a 2-minute SIGTERM warning, you lose at most ~7 minutes of work per interruption. On a 4-hour job interrupted once, that is <3% waste.

### Scaling to Zero

`min_vcpus = 0` on both compute environments means AWS terminates all EC2 instances when no jobs are queued. This is the single most important cost control for a batch service.

**Do not set `min_vcpus > 0`** unless you need sub-60-second job start times. Keeping warm instances running 24/7 costs ~$150–300/month per instance before running a single job.

### S3 Storage Cost Optimization

Checkpoints are the dominant storage cost — a long run can produce hundreds of intermediate checkpoints, each potentially hundreds of MB.

**Recommended lifecycle for the output bucket:**

```
Day 0–30:   S3 Standard              (fast access, debugging, active downloads)
Day 30–90:  S3 Standard-IA           (infrequent access, ~45% cheaper)
Day 90–180: S3 Glacier Instant       (rare access, ~68% cheaper, ms retrieval)
Day 180+:   S3 Glacier Deep Archive  (archival, ~95% cheaper, 12h retrieval)
```

Additionally:
- **Delete non-final checkpoints** after job completion. The best program is in the final checkpoint; intermediate ones are only needed for debugging and can be pruned after 14 days.
- **Input bucket**: No lifecycle needed — inputs are KB-sized and lifecycle cost is negligible.
- **Failed job artifacts**: Delete outputs of FAILED jobs after 14 days (a Lambda on EventBridge can automate this).

### Network Cost: NAT Gateway

NAT Gateway charges $0.045/GB for all outbound traffic from private subnets. Sources of NAT Gateway traffic:

1. ECR image pulls: ~2–4 GB per cold start
2. Gemini API LLM calls: ~50–200 MB per job (prompt + response payloads)
3. S3 checkpoint uploads: ~100–500 MB per job

**VPC endpoints eliminate NAT Gateway charges for AWS services:**
- `com.amazonaws.<region>.s3` (Gateway endpoint — free)
- `com.amazonaws.<region>.ecr.api` and `ecr.dkr` (Interface endpoints — $7.30/month each, break even at ~160 GB/month of ECR traffic)

Add S3 Gateway endpoint immediately (free, no downside). Add ECR Interface endpoints once you have regular image pulls (multiple jobs/day).

Gemini API traffic must traverse NAT Gateway — there is no endpoint for external APIs.

### Cost Attribution and Per-User Visibility

Every resource should be tagged:

```hcl
tags = {
  Owner       = var.username     # set per job submission
  JobShortId  = var.short_id
  Environment = var.environment  # prod / dev
  Service     = "openevolve"
}
```

AWS Cost Explorer filtered by `Owner` tag gives per-user spend. This enables:
- Monthly spend reports per user
- Detecting runaway jobs (a user accidentally submitting 50-iteration jobs for a week)
- Chargeback if needed

**AWS Budgets**: Set one budget for total service cost, and optionally per-user budgets using tag-based filters. Alert at 80% and 100% of monthly limit.

### Right-Sizing Over Time

After 30 days of production use, pull CloudWatch metrics for actual CPU and memory utilization per job. Common finding: jobs use 60% of requested vCPUs on average because evaluation is partly network-blocked. If so, reduce default vCPUs from 8 to 6 — a 25% cost reduction with no loss of throughput.

---

## 3. Scalability

### Job Throughput

AWS Batch auto-scales compute environments based on queue depth:
- When jobs enter RUNNABLE state, Batch provisions new EC2 instances (typically within 1–3 minutes)
- When the queue drains, instances are terminated after a drain period

Effective throughput is bounded by `max_vcpus / vcpus_per_job`. With the current defaults:

```
256 max_vcpus / 8 vcpus_per_job = 32 concurrent jobs
```

Increase `max_vcpus` in `terraform.tfvars` to scale further. AWS service quotas limit Spot vCPU usage per region — request a quota increase from AWS Support before exceeding ~500 vCPUs.

### Multiple Job Queues

A single queue with two compute environments works for an initial deployment. As usage grows, add separate queues for different workload tiers:

```
openevolve-high    → dedicated On-Demand CE, small max_vcpus, for urgent/debug jobs
openevolve-prod    → Spot-first (current), standard jobs
openevolve-dev     → On-Demand only, lower max_vcpus, for development/testing
```

This prevents a developer submitting 100 test iterations from consuming Spot capacity away from a production 10,000-iteration job.

### AWS Batch Fair Share Scheduling

When multiple users share one queue, AWS Batch Fair Share scheduling ensures no single user monopolizes capacity:

```json
{
  "shareDistribution": [
    { "shareIdentifier": "alice*",  "weightFactor": 1.0 },
    { "shareIdentifier": "bob*",    "weightFactor": 1.0 },
    { "shareIdentifier": "ron*",    "weightFactor": 1.0 }
  ]
}
```

Jobs are tagged with the owner's username as the share identifier. Batch distributes capacity proportionally according to weight factors, with decay over time so idle users' unused share becomes available to active ones.

### Parallelism Within a Job

OpenEvolve's internal parallelism (`ProcessPoolExecutor`) scales with available vCPUs. For a job that benefits from very high parallelism (many short-lived evaluations), submit it with `--vcpus 32` to get a 4xlarge instance. The per-job cost is the same per CPU-hour — you just get results faster.

For evaluators that compile and run code, wall-clock time is often dominated by compilation (single-threaded). In this case, more vCPUs do not help — use smaller instances and submit more independent jobs instead.

### Multi-Region

A single-region deployment is acceptable initially. Consider a second region when:
- Spot capacity in us-east-1 becomes constrained (queues backing up for >30 minutes)
- Regulatory requirements demand data residency in a specific region
- You need geographic redundancy for the S3 output bucket

A second-region deployment is a separate Terraform workspace with its own compute environments. S3 Cross-Region Replication can mirror outputs from the primary region.

---

## 4. Monitoring

### Layers of Observability

Effective monitoring requires three complementary layers: metrics for trends, logs for debugging, and traces for latency attribution.

### Infrastructure Metrics (CloudWatch)

**AWS Batch** (built-in, no agent needed):
| Metric | Alert Threshold | Action |
|---|---|---|
| `JobsPendingCount` | > 50 for 30 min | Check Spot availability, expand instance pool |
| `JobsFailedCount` | > 5 in 1 hour | Check logs for application errors |
| `JobsRunningCount` | Sudden drop to 0 | Spot interruption event or account limit hit |

**EC2 via CloudWatch Agent** (installed in Docker image or on host):
- CPU utilization per instance: alert if sustained < 20% (wasted capacity) or sustained > 95% (memory pressure)
- Memory utilization: alert at > 85% (risk of OOM kill)
- Disk I/O: only relevant if evaluators write large temporary files

### Application Metrics (Custom)

OpenEvolve should emit custom CloudWatch metrics at the end of each iteration. Add to `openevolve/controller.py` or the entrypoint:

```python
import boto3
cw = boto3.client("cloudwatch", region_name=os.environ["AWS_DEFAULT_REGION"])

cw.put_metric_data(
    Namespace="OpenEvolve",
    MetricData=[
        {
            "MetricName": "BestScore",
            "Value": best_score,
            "Unit": "None",
            "Dimensions": [
                {"Name": "JobId",   "Value": job_id},
                {"Name": "Owner",   "Value": owner},
            ]
        },
        {
            "MetricName": "IterationThroughput",
            "Value": iterations_per_hour,
            "Unit": "Count/Second",
            "Dimensions": [{"Name": "JobId", "Value": job_id}]
        },
        {
            "MetricName": "LLMCallSuccessRate",
            "Value": success_rate,
            "Unit": "Percent",
            "Dimensions": [{"Name": "JobId", "Value": job_id}]
        },
    ]
)
```

These metrics enable the CloudWatch dashboard to show evolution quality over time, not just infrastructure health.

### Alerting Tiers

**Page (immediate response required):**
- `JobsFailedCount > 10` in 1 hour (systematic failure, not one-offs)
- Monthly budget exceeded 100%
- S3 write failures (data loss risk)

**Notify (investigate within business hours):**
- `JobsFailedCount > 3` in 1 hour
- Budget at 80% of monthly limit
- Spot interruption rate > 50% (jobs being interrupted faster than they complete)
- LLM API error rate > 20% (Gemini quota, key expiry)

**Log only (review weekly):**
- Individual job failures
- Checkpoint sync failures (non-fatal, retried automatically)

### CloudWatch Dashboard Layout

Recommended widgets for the main dashboard:

```
Row 1: Jobs Running | Jobs Pending | Jobs Failed (24h) | Monthly Spend
Row 2: Best Score by Job (line chart, last 7 days)
Row 3: Iteration Throughput by Job (line chart)
Row 4: CPU Utilization (heatmap by instance)
Row 5: LLM API Success Rate | S3 Bytes Written | NAT Gateway Traffic
```

### Log Analysis

CloudWatch Logs Insights queries for common debugging tasks:

```sql
-- Find all errors in last 24 hours
fields @timestamp, @message
| filter @message like /ERROR/
| sort @timestamp desc
| limit 100

-- Iteration throughput per job
fields @timestamp, @message
| filter @message like /iteration complete/
| stats count() as iterations by jobId
| sort iterations desc

-- Evaluator failure rate
fields @message
| filter @message like /evaluation failed/
| stats count() as failures by programHash
| sort failures desc
```

Set log retention to 30 days (already configured). Archive to S3 for 1 year via a CloudWatch Logs subscription filter if compliance requires it.

---

## 5. Security

### IAM Posture

The current implementation correctly separates four IAM principals with minimal permissions:

```
Batch Service Role     — Batch control plane operations
EC2 Instance Role      — ECS agent, ECR pull, CloudWatch Logs
Batch Job Role         — S3 read/write (users/* prefix), CloudWatch PutMetricData
ECS Execution Role     — Secrets Manager read (for Gemini key injection)
```

Hardening steps beyond the current implementation:

1. **IAM Permission Boundaries**: Attach a permission boundary to the batch job role that caps maximum permissions. Even if the role policy is overly permissive, the boundary enforces a ceiling.

2. **S3 Bucket Policy** (defense in depth): In addition to IAM policies, add a bucket policy that explicitly denies access to any principal that is not the batch job role or an authorized IAM user. This prevents privilege escalation via a compromised admin role from accessing user data.

3. **SCPs at Organization Level**: If using AWS Organizations, apply a Service Control Policy that:
   - Denies `s3:DeleteBucket` on the OpenEvolve buckets
   - Restricts actions to `us-east-1` only (prevents exfiltration to other regions)
   - Denies `iam:CreateUser` from within the batch job role (prevents container escape to create new principals)

### Secrets Rotation

The Gemini API key in Secrets Manager should rotate every 90 days. Automation options:

1. **Manual rotation with Lambda notification**: A CloudWatch Events rule triggers a Lambda 14 days before rotation deadline, sending an email reminder.
2. **Automatic rotation**: If Gemini exposes a key rotation API, a Lambda rotation function can handle this automatically. Otherwise, semi-automatic: Lambda updates the secret, sends notification.

Critically: the running container reads the secret at startup, not continuously. Rotation only takes effect on the next job submission. This is acceptable.

### Container Security

The current Dockerfile runs as root inside the container. Harden for production:

```dockerfile
# Create non-root user
RUN useradd -m -u 1000 openevolve

# Set ownership on writable directories only
RUN mkdir -p /tmp/openevolve && chown openevolve:openevolve /tmp/openevolve

USER openevolve
```

Additionally, add to the job definition's `containerProperties`:

```json
{
  "readonlyRootFilesystem": true,
  "privileged": false,
  "user": "1000"
}
```

One exception: the evaluator may need to install packages or write to arbitrary paths. If so, use a named volume mounted at `/tmp` (already writable) and keep the rootfs read-only.

### Network Controls

The current VPC design (private subnets, NAT Gateway) is correct. Additional controls:

- **Security group egress**: Restrict to HTTPS (443) only. OpenEvolve has no reason to make non-HTTPS outbound connections. This prevents a compromised container from exfiltrating data via arbitrary ports.
- **VPC Flow Logs**: Enable on the VPC and ship to CloudWatch. Provides audit trail for all network connections and aids incident investigation.
- **No SSH/SSM on Batch instances**: AWS Batch EC2 instances should not be SSHable. Use CloudWatch Logs for debugging, not direct shell access.

### Audit Logging

Enable CloudTrail in the account with:
- All management events (job submission, IAM changes, S3 bucket operations)
- S3 data events on both buckets (GetObject, PutObject) — adds cost but provides forensic audit trail
- Integrity validation enabled on the CloudTrail S3 bucket

---

## 6. Reliability

### Failure Taxonomy

Understanding failure modes prevents overengineering:

| Failure | Frequency | Recovery |
|---|---|---|
| Spot interruption | 5–15%/instance-hour | Automatic (checkpoint + retry) |
| LLM API rate limit | Occasional | OpenEvolve retry logic handles this |
| LLM API key expiry | Rare | Job fails; re-enter key, resubmit |
| OOM kill | Rare | Increase memory in job definition |
| Evaluator bug (exception) | Common in development | Job fails; fix evaluator, resubmit |
| S3 sync failure | Very rare | Background sync is `|| true`; next sync succeeds |
| EC2 hardware failure | Very rare | Batch detects and retries on new instance |

### Retry Configuration

The current retry policy correctly distinguishes Spot interruptions from application failures:

```json
{
  "attempts": 3,
  "evaluateOnExit": [
    {
      "onStatusReason": "Host EC2*",
      "action": "RETRY"     // Spot interrupted — retry on new instance
    },
    {
      "onReason": "CannotPullContainerError*",
      "action": "RETRY"     // Transient ECR issue
    },
    {
      "onExitCode": "1",
      "action": "EXIT"      // Application error — don't waste retries
    }
  ]
}
```

**Do not retry on exit code 1** — that indicates an OpenEvolve or evaluator error. Retrying 3 times wastes money and time on a job that will fail identically each time. Fail fast and let the user investigate.

### Checkpoint Frequency Tuning

The current implementation syncs to S3 every 5 minutes. This is the right default. For jobs longer than 24 hours, consider tuning OpenEvolve's internal checkpoint frequency:

```yaml
# config.yaml
checkpoint_interval: 50  # save checkpoint every 50 iterations
```

With a 5-minute S3 sync and checkpoints every 50 iterations, the maximum work lost on interruption is `max(5 minutes, time_for_50_iterations)`. For fast evaluators (1s each), 50 iterations takes 50 seconds — the 5-minute sync is the binding constraint.

### Dead Letter Handling

Jobs that exhaust all retries enter FAILED state. Currently they are only logged. Add:

1. **EventBridge rule** on `"detail-type": "Batch Job State Change"` with `"status": "FAILED"`
2. **Lambda function** triggered by the rule that:
   - Posts to SNS (email notification)
   - Records to DynamoDB with job metadata (for audit and resubmission)
   - Optionally posts to a Slack webhook for immediate visibility

This turns silent failures into actionable notifications.

---

## 7. Operational Excellence

### CI/CD for the Docker Image

The current workflow requires manually rebuilding and pushing the Docker image after every code change. Replace with GitHub Actions:

```yaml
# .github/workflows/docker.yml
on:
  push:
    branches: [main]
    paths: ['openevolve/**', 'Dockerfile.aws', 'docker-entrypoint.sh']

jobs:
  build-push:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          aws-access-key-id: ${{ secrets.AWS_ACCESS_KEY_ID }}
          aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
          aws-region: us-east-1
      - name: Login to ECR
        id: login-ecr
        uses: aws-actions/amazon-ecr-login@v2
      - name: Build and push
        env:
          ECR_URL: ${{ steps.login-ecr.outputs.registry }}/openevolve-prod
          IMAGE_TAG: ${{ github.sha }}
        run: |
          docker build -f Dockerfile.aws -t $ECR_URL:$IMAGE_TAG -t $ECR_URL:latest .
          docker push $ECR_URL:$IMAGE_TAG
          docker push $ECR_URL:latest
```

New jobs automatically use `latest`. For reproducibility, pin specific jobs to a SHA tag:
```bash
openevolve-aws submit --program prog.py --evaluator eval.py --image-tag abc1234
```

### Infrastructure Changes

Terraform changes should go through a review process:

```
Developer → terraform plan (in CI)
         → PR review (human approval for plan output)
         → terraform apply (on merge to main, via CI with locked state)
```

Use `terraform plan -detailed-exitcode` to fail CI if there are unexpected changes. The DynamoDB lock prevents concurrent applies from racing.

Separate Terraform workspaces for dev and prod prevent dev experimentation from affecting production infrastructure.

### Capacity Planning

Review the following quarterly:

1. **Spot interruption rate per instance type**: If any type has >30% interruption rate, remove it from the pool.
2. **Average job duration**: If growing (users submitting larger runs), adjust max_vcpus accordingly.
3. **S3 storage growth**: Project forward 6 months; set lifecycle rules before storage becomes expensive.
4. **Gemini API costs**: If LLM call costs dominate, evaluate caching identical prompts or switching to a smaller model for low-creativity iterations.

### Runbook: Common Incidents

**Jobs stuck in RUNNABLE for > 30 minutes**
```bash
# Check Spot availability
aws ec2 describe-spot-price-history \
  --instance-types m5.2xlarge c5.2xlarge \
  --product-descriptions "Linux/UNIX" \
  --start-time $(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Resolution: add more instance types to compute environment
# OR: temporarily increase On-Demand CE max_vcpus
```

**High job failure rate**
```bash
# Inspect last 10 failed jobs
aws batch list-jobs --job-queue openevolve-prod-queue --job-status FAILED \
  --query 'jobSummaryList[*].{id:jobId,reason:statusReason}' | head -10

# Check container logs for first failure
openevolve-aws logs <job-id>

# Common causes:
# - "OPENAI_API_KEY not set" → Secrets Manager key missing/invalid
# - "evaluator.py not found" → S3 upload failed before submission
# - "OOMKilled" → increase memory in job definition
```

**Budget alert triggered**
```bash
# Find top spenders by tag
aws ce get-cost-and-usage \
  --time-period Start=$(date -d '-30 days' +%Y-%m-%d),End=$(date +%Y-%m-%d) \
  --granularity MONTHLY \
  --metrics BlendedCost \
  --group-by Type=TAG,Key=Owner

# Identify runaway jobs
openevolve-aws list RUNNING
# Cancel any unexpected long-running jobs
```

---

## 8. Data Management

### Retention Policy

| Data | Storage Class | Retention | Rationale |
|---|---|---|---|
| Job inputs | S3 Standard | 30 days then delete | Small; can always resubmit |
| Job outputs (best program) | Standard → IA → Glacier | 1 year | User's primary deliverable |
| Intermediate checkpoints | Standard → IA | 90 days | Debugging only; not needed long-term |
| Failed job outputs | Standard | 14 days then delete | Not worth keeping |
| CloudWatch Logs | — | 30 days hot | Archive to S3 for 1 year if needed |
| CloudTrail | S3 Standard | 7 years | Compliance/audit |

### Cleanup Automation

A Lambda function on a daily EventBridge schedule handles lifecycle cleanup that S3 lifecycle rules cannot:

```python
def handler(event, context):
    # Delete outputs of jobs that FAILED > 14 days ago
    for job in list_failed_jobs_older_than(days=14):
        s3.delete_prefix(f"users/{job.owner}/{job.short_id}/")

    # Delete intermediate checkpoints, keeping only latest
    for job in list_completed_jobs():
        prune_checkpoints(job, keep_latest=1)
```

This is more targeted than S3 lifecycle rules, which act on age alone without regard for job outcome.

---

## 9. Multi-Tenancy

### Current Model

The current implementation provides lightweight isolation: each IAM user can only read/write their own S3 prefix. They share a Batch queue, compute environments, CloudWatch namespace, and the Gemini API key.

This is appropriate for a small team of trusted users. It breaks down at scale or with untrusted users.

### Stronger Isolation Options

**Separate S3 prefixes** (current): Simple, no overhead. Does not prevent one user's jobs from delaying another's (shared queue capacity).

**Fair Share Scheduling** (next step): Prevents queue monopolization. Add scheduling policy to the job queue with equal shares per user. Cost: minimal Terraform change.

**Separate API Keys per user**: Prevents one user's Gemini quota exhaustion from affecting others. Trade-off: higher key management overhead. Recommended once user count exceeds ~5.

**Separate Job Definitions per user**: Allows per-user resource limits (max vCPUs, max memory). Useful if users have different workload profiles.

**Separate AWS Accounts** (maximum isolation): Each user gets their own AWS account via AWS Organizations. Full billing, security, and quota isolation. Overhead is high; only warranted for external customers or strict compliance requirements.

### Quotas

Implement soft quotas via a submission Lambda (invoked before `batch:SubmitJob`):

```python
def check_quota(username):
    running = count_running_jobs_for_user(username)
    if running >= MAX_CONCURRENT_JOBS_PER_USER:
        raise QuotaExceeded(f"{username} already has {running} running jobs")
```

This Lambda sits between the CLI and Batch, adding a governance layer without changing the underlying AWS permissions.

---

## 10. Cost Model Summary

For a team of 5 users running typical workloads (2–3 concurrent jobs, 4–8 hour durations, 100 iterations each):

| Component | Est. Monthly Cost | Notes |
|---|---|---|
| EC2 Spot (m5.2xlarge) | $80–150 | ~500 instance-hours/month |
| EC2 On-Demand fallback | $20–40 | 10–15% of jobs hit fallback |
| NAT Gateway | $15–30 | Data processing + hourly |
| S3 storage | $5–15 | Output accumulates over time |
| S3 requests | $2–5 | Checkpointing |
| ECR storage | $2–5 | Docker image layers |
| Secrets Manager | $1 | Single secret |
| CloudWatch | $5–10 | Logs, metrics, dashboard |
| **Total** | **~$130–255/month** | Scales linearly with job volume |

At 10x job volume (50 concurrent jobs), EC2 costs dominate and Spot savings become more impactful. At that scale, a Compute Savings Plan covering the On-Demand fallback saves an additional 15–20%.
