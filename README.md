# CSV Processing Platform
# CSV Processing Pipeline

Terraform for a CSV upload and processing pipeline running in `eu-north-1` (Stockholm). Files go in via the browser, get scrubbed of PII, enriched through an external API, and loaded into Postgres. Processing takes roughly 5–10 minutes per file depending on size.

---

## How it works

```
Browser → API Gateway → S3 (presigned upload) → EventBridge → Step Functions
→ Fargate (scrub → enrich → load) → RDS Postgres

Job state: DynamoDB
Notifications: SNS
DR: S3 cross-region replication → eu-central-1 (Frankfurt)
```

The upload goes directly from the browser to S3 — API Gateway has a 10 MB body limit so routing a 5 GB file through it was never an option. Once the file lands in S3, EventBridge picks it up and kicks off a Step Functions execution that runs three Fargate containers in sequence.

---

## What gets created

| File | What it creates |
|---|---|
| `main.tf` | KMS key, S3 buckets, DynamoDB, SNS topics, Secrets Manager entries |
| `api.tf` | API Gateway HTTP API, two Lambdas (request-upload, get-status) |
| `ecs.tf` | ECS cluster, three Fargate task definitions (scrub, enrich, load) |
| `stepfunctions.tf` | Step Functions state machine with retry and catch per stage |
| `eventbridge.tf` | EventBridge rule that fires when a file lands in the uploads bucket |
| `iam.tf` | IAM roles — one per Fargate task, plus Step Functions, EventBridge, and S3 replication |
| `network.tf` | VPC, two private subnets, one public subnet, NAT Gateway, VPC endpoints |
| `rds.tf` | RDS Postgres 16, Multi-AZ |
| `dr.tf` | Frankfurt KMS key, DR bucket, cross-region replication config |

---

## Before you start

You'll need:
- Terraform >= 1.5.0
- AWS CLI set up and authenticated (`aws sso login --profile <profile>` or however your account works)
- Three Docker images already pushed to ECR — one for each stage: `scrub`, `enrich`, `load`
- An email address to receive ops alerts

---

## Getting started

### 1. Clone and init

```bash
git clone <your-repo>
cd <your-repo>
terraform init
```

### 2. Create a tfvars file

Don't edit `variables.tf` directly. Create your own:

```hcl
# terraform.tfvars
env          = "dev"
ecr_repo_url = "123456789012.dkr.ecr.eu-north-1.amazonaws.com/csv-pipeline"
image_tag    = "latest"
notify_email = "your-team@company.com"
db_username  = "csvapp"
db_name      = "customers"
```

### 3. Plan and apply

```bash
terraform plan -var-file="terraform.tfvars"
terraform apply -var-file="terraform.tfvars"
```

### 4. Get your API URL

```bash
terraform output api_endpoint
```

---

## API

Two endpoints — that's it.

| Method | Path | What it does |
|---|---|---|
| `POST` | `/uploads` | Returns a presigned S3 URL and a `jobId` |
| `GET` | `/jobs/{jobId}` | Returns current job status |

### Request an upload URL

```bash
curl -X POST https://<api-endpoint>/uploads \
  -H "Content-Type: application/json" \
  -d '{"filename": "customers.csv", "contentType": "text/csv"}'
```

### Check job status

```bash
curl https://<api-endpoint>/jobs/<jobId>
```

---

## Job statuses

| Status | What it means |
|---|---|
| `PENDING` | File uploaded, pipeline hasn't started yet |
| `RUNNING` | Step Functions execution started |
| `SCRUBBED` | PII removed, waiting for enrich |
| `ENRICHED` | External API done, waiting for load |
| `SUCCEEDED` | In Postgres, user notified |
| `FAILED` | Something went wrong — check the ops SNS alert and CloudWatch logs |

---

## Variables

| Variable | Default | Notes |
|---|---|---|
| `region` | `eu-north-1` | Primary region — Stockholm |
| `dr_region` | `eu-central-1` | DR region — Frankfurt |
| `env` | `dev` | Appended to all resource names |
| `ecr_repo_url` | — | Your ECR repo, not the placeholder |
| `image_tag` | `latest` | Pin this to a real tag for prod |
| `db_username` | `csvapp` | RDS master user |
| `db_name` | `customers` | RDS database name |
| `notify_email` | — | Where ops alerts go |

---

## Outputs

| Output | Description |
|---|---|
| `api_endpoint` | API Gateway URL |
| `uploads_bucket` | Primary upload bucket |
| `uploads_dr_bucket` | DR bucket in Frankfurt |
| `processed_bucket` | Intermediate files bucket |
| `state_machine_arn` | Step Functions ARN |
| `rds_endpoint` | RDS connection endpoint |
| `jobs_table` | DynamoDB table name |

---

## Folder structure

```
.
├── main.tf
├── api.tf
├── ecs.tf
├── stepfunctions.tf
├── eventbridge.tf
├── iam.tf
├── network.tf
├── rds.tf
├── dr.tf
├── variables.tf
├── outputs.tf
├── versions.tf
└── lambda/
    ├── request_upload.py
    └── get_status.py
```

---

## Building and pushing the Fargate images

You need three images before the pipeline can actually run anything. Each stage is a separate container.

```bash
# Log in to ECR
aws ecr get-login-password --region eu-north-1 | \
  docker login --username AWS --password-stdin <account-id>.dkr.ecr.eu-north-1.amazonaws.com

# Build and push scrub, enrich, load
for stage in scrub enrich load; do
  docker build -t csv-pipeline/$stage ./src/$stage
  docker tag csv-pipeline/$stage <ecr-repo-url>/$stage:latest
  docker push <ecr-repo-url>/$stage:latest
done
```

Each container gets these at runtime:

| Variable | Where it comes from |
|---|---|
| `STAGE` | Task definition |
| `UPLOADS_BUCKET` | Task definition |
| `PROCESSED_BUCKET` | Task definition |
| `JOBS_TABLE` | Task definition |
| `JOB_ID` | Step Functions input override |
| `INPUT_KEY` | Step Functions input override |
| `ENRICH_API_KEY` | Secrets Manager — enrich task only |
| `DB_PASSWORD` | Secrets Manager — load task only |

---

## Before you go to production

A few things are deliberately left loose for dev. Don't forget to flip these:

- [ ] `force_destroy = false` on all S3 buckets (`main.tf`, `dr.tf`) — right now `terraform destroy` will delete everything in them without warning
- [ ] `skip_final_snapshot = false` on RDS (`rds.tf`)
- [ ] `deletion_protection = true` on RDS (`rds.tf`)
- [ ] Lock down `allow_origins = ["*"]` on API Gateway and S3 CORS to your actual domain
- [ ] Add authentication to the API — there's none right now. Cognito or a Lambda authorizer, either works
- [ ] Add WAF to API Gateway
- [ ] Add a manual approval step in the CodeBuild pipeline so someone reviews the plan before it applies to prod
- [ ] Replace `REPLACE_ME` in the enrich API secret with the real key
- [ ] Pin `image_tag` to a specific version rather than `latest`
- [ ] Check with legal on the enrichment vendor — if they're US-based you need a DPA in place before PII flows through enrich

---

## Tearing it down

```bash
terraform destroy -var-file="terraform.tfvars"
```

Fair warning — `force_destroy = true` is set on the S3 buckets in dev so this will delete all objects in them. That's intentional for dev. It's exactly why that flag needs flipping before anything important goes in.

---

## A few things worth knowing

- The raw uploads bucket expires files after 1 day. Once scrub has run, the original is gone. That's on purpose.
- Only the enrich task routes through the NAT Gateway — it's the only one calling an external API. Everything else (S3, KMS, ECR, Secrets Manager, logs) goes through VPC endpoints and never touches the NAT.
- Each Fargate task has its own IAM role and can only access the S3 prefix it needs. Scrub can't read what load writes, and so on.
- Secrets are injected at container startup via Secrets Manager — not hardcoded, not in environment variables in the task definition.
- The DB password is generated by Terraform on first apply and stored in Secrets Manager. You don't need to set it manually.

---

## CI/CD

Deployments run through AWS CodeBuild on merge to `main`:

```
terraform init → terraform plan → terraform apply
```

State lives in S3 with a DynamoDB lock table to stop concurrent applies stomping on each other. See `buildspec.yml` in the repo root for the full build config.
````](#)
