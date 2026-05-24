# High Level Design — CSV Processing Platform
**Version:** 1.0  

---

## Table of Contents
1. [Document Purpose & Scope](#1-document-purpose--scope)
2. [Non-Functional Requirements](#3-non-functional-requirements)
3. [Architecture Overview](#4-architecture-overview)
4. [Component Design](#5-component-design)
5. [Decision Log](#7-decision-log)
5. [Trade-offs](#8-trade-offs)
7. [GDPR / PII Posture](#9-gdpr--pii-posture)
8. [Deployment & CI/CD](#10-deployment--cicd)
9. [Open Items & Future Work](#11-open-items--future-work)

---

## 1. Document Purpose & Scope

This document describes the high level design for the CSV Processing Platform — a system that allows users to upload large CSV files (up to 5 GB), automatically scrub PII, enrich records via an external API, and load clean data into the main database.

### In Scope
- Browser-based CSV upload (up to 5 GB)
- Automated PII scrubbing, enrichment, and database load pipeline
- Job status tracking and user notifications
- Infrastructure as Code (Terraform)
- Security, encryption, and GDPR compliance posture

### Out of Scope
- Frontend UI implementation
- Business logic inside the black-box processor
- Enrichment vendor selection or contract
- User authentication / Cognito setup (flagged for production)
- WAF configuration (flagged for production)

---

## 2. Non-Functional Requirements

These numbers are our current best estimates. The concurrent upload figure especially needs validating — see Open Items.

- **Max file size:** 5 GB
- **Processing SLA:** under 15 minutes end-to-end
- **Availability target:** 99.9% — covered by Multi-AZ RDS and Fargate across two AZs
- **Region:** eu-north-1 (Stockholm), single region
- **Concurrent uploads:** up to 20 simultaneous — assumed, not yet load tested
- **Raw PII retention:** 1 day (lifecycle expiry on uploads bucket)
- **Processed data retention:** 90 days, configurable
- **RTO on DB failure:** under 2 minutes (Multi-AZ automatic failover)
- **RPO:** under 1 minute (Multi-AZ synchronous replication)
- **Encryption:** KMS CMK end-to-end

---

## 3. Architecture Overview

### One-Line Summary
> Browser → S3 presigned multipart upload → EventBridge → Step Functions → three Fargate tasks (scrub → enrich → load) → RDS Postgres, with DynamoDB for job state and SNS for notifications.

### Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────────┐
│                        eu-north-1 (Stockholm)                       │
│                                                                     │
│   Browser                                                           │
│     │                                                               │
│     │ 1. Request presigned URL                                      │
│     ▼                                                               │
│  API Gateway (HTTP API)                                             │
│     │                                                               │
│     ├── /request-upload → Lambda (generate presigned URL)          │
│     └── /get-status     → Lambda (poll DynamoDB)                   │
│          │                          ▲                               │
│          │ 2. Presigned URL         │ status reads                  │
│          ▼                          │                               │
│   Browser ──multipart PUT──► S3 Uploads Bucket ◄── CloudTrail      │
│                                     │                               │
│                            3. S3 Event                              │
│                                     ▼                               │
│                               EventBridge                           │
│                                     │                               │
│                            4. Trigger                               │
│                                     ▼                               │
│                          Step Functions (Standard)                  │
│                          ┌──────────────────────┐                  │
│                          │  scrub → enrich → load│                  │
│                          └──────────────────────┘                  │
│                               │        │        │                   │
│                               ▼        ▼        ▼                   │
│                    ┌─────── ECS Fargate Tasks ──────────┐          │
│                    │  Task 1   │  Task 2  │   Task 3    │          │
│                    │  (scrub)  │ (enrich) │   (load)    │          │
│                    └───────────────────────────────────-┘          │
│                         │         │ (ext API)     │                 │
│                         │         ▼               │                 │
│                    S3 Processed  External API    RDS Postgres       │
│                    Bucket        (egress via      (Multi-AZ)        │
│                                   NAT GW)                           │
│                                                                     │
│   DynamoDB (job state) ◄── Step Functions updates throughout        │
│   SNS (notifications)  ◄── Step Functions on success/failure        │
│                                                                     │
│ ┌─────────────────────── VPC ───────────────────────────────────┐  │
│ │  Public Subnet          │      Private Subnet (x2 AZ)         │  │
│ │  - NAT Gateway          │      - Fargate Tasks                 │  │
│ │  - Internet Gateway     │      - RDS (Multi-AZ)               │  │
│ │                         │      - VPC Endpoints                 │  │
│ │                         │        (S3, KMS, SM, ECR, Logs)      │  │
│ └──────────────────────────────────────────────────────────────-┘  │
│                                                                     │
│  DR: S3 cross-region replication ──► eu-central-1 (Frankfurt)      │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 4. Component Design

### 4.1 Upload Path — API Gateway + S3 Presigned URL

User calls `POST /request-upload` via API Gateway HTTP API. Lambda generates an S3 presigned multipart upload URL valid for 60 minutes. The browser uploads directly to S3 in parallel parts — this completely bypasses API Gateway's 10 MB and Lambda's 6 MB limits. On upload complete, S3 emits an event to EventBridge.

### 4.2 Event Routing — EventBridge

S3 `ObjectCreated` events are forwarded to EventBridge. A rule matches on the uploads bucket prefix and triggers Step Functions. The decoupling is intentional — future consumers like an audit log or analytics pipeline can subscribe to the same event without touching the upload path.

### 4.3 Orchestration — Step Functions Standard Workflow

```
[Start]
   │
   ▼
[Scrub Task]  ──fail──► [Catch → Update DDB → SNS Error]
   │
   ▼
[Enrich Task] ──fail──► [Catch → Update DDB → SNS Error]
   │
   ▼
[Load Task]   ──fail──► [Catch → Update DDB → SNS Error]
   │
   ▼
[Update DDB: COMPLETE]
   │
   ▼
[SNS: Notify User Success]
   │
[End]
```

Per-stage retry with exponential backoff. Full execution history visible in the AWS Console. Runs well beyond the 15-minute Lambda ceiling.

### 4.4 Compute — ECS Fargate (3 Task Definitions)

| Task | Responsibility | IAM Scope |
|---|---|---|
| scrub | Read from uploads bucket, remove PII fields, write to processed bucket | Read uploads prefix, write processed prefix |
| enrich | Read processed, call external API, write enriched output | Read processed prefix, write enriched prefix, NAT egress |
| load | Read enriched file, bulk COPY INTO RDS Postgres | Read enriched prefix, RDS write |

No 15-min Lambda ceiling. Real filesystem for large file handling. No EKS overhead for a three-task pipeline.

### 4.5 Job State — DynamoDB

Schema: `jobId (PK)` → `{ status, fileName, startedAt, updatedAt, error }`

Step Functions writes a status update at each stage transition. The `GET /get-status` Lambda reads directly from DynamoDB — single-digit millisecond reads, no connection pool overhead.

### 4.6 Final Sink — RDS Postgres Multi-AZ

Bulk load via `COPY FROM` for fast ingestion. Multi-AZ for automatic failover under two minutes. Credentials stored in Secrets Manager and injected as ECS task secrets at runtime.

### 4.7 Notifications — SNS

Two topics: `user-notifications` and `ops-alerts`. User topic sends email on success or failure. Ops topic fires to PagerDuty or Slack on failure. Easy to extend without touching the pipeline.

### 4.8 Status API — API Gateway + Lambda

- `POST /request-upload` — returns presigned URL and jobId, creates DynamoDB record
- `GET /get-status?jobId=xxx` — returns current job status from DynamoDB

HTTP API chosen over REST API — roughly 70% cheaper, more than sufficient for two lightweight JSON endpoints.

---

## 5. Decision Log

Here is logic behind slecting ecah component .

**Region — eu-north-1**
Company is in Stockholm, users are in Stockholm, data should be in Stockholm. It's also around 10–15% cheaper than Frankfurt and runs on 100% renewable energy.

**Upload path — presigned multipart directly to S3**
API Gateway has a 10 MB body limit. Lambda has a 6 MB synchronous payload limit. Neither of those work for 5 GB files. Direct browser-to-S3 via presigned multipart URL sidesteps both completely and is actually faster because the browser can upload parts in parallel. This one wasn't really a debate.

**EventBridge between S3 and Step Functions**
I could have gone S3 → Lambda → Step Functions, or even S3 → Step Functions directly. I went via EventBridge because it decouples the upload event from the processing pipeline. If i want to add an audit trail, an analytics feed, or a virus scanner later, i just add another EventBridge rule — i don't touch the upload path or the pipeline. That kind of extensibility is worth the extra hop.

**Step Functions Standard over Express**
Express Workflows cap at five minutes. Our processing target is 5–10 minutes per file. That's a hard no. Standard Workflows also give us per-stage retry and catch logic, full execution history in the console, and native integrations with ECS, DynamoDB, and SNS. The cost difference is negligible at our scale.

**Fargate over Lambda for the processing tasks**
Lambda's 15-minute ceiling is cutting it close for large files, and the 10 GB ephemeral storage limit adds risk. More importantly, Lambda's execution model isn't a natural fit for long-running, filesystem-heavy data processing. Fargate gives us a real container, a real filesystem, and no arbitrary time limits. I looked at Batch briefly — it adds a scheduling layer that buys us nothing here. I looked at Glue — it's not designed for rate-limited REST API calls in a sequential pipeline.

**DynamoDB for job state**
The job state schema is dead simple — a job ID maps to a status and a few timestamps. That's a key-value lookup, not a relational query. DynamoDB gives us single-digit millisecond reads for the status polling endpoint without burning RDS connections on operational data. Using RDS here would have been the wrong tool.

**RDS Postgres Multi-AZ over Aurora Serverless v2**
The problem statement specifies a "main database" and write patterns aren't clear yet. RDS Postgres is the safe, predictable choice. Aurora Serverless v2 is a genuine alternative — worth revisiting after launch if writes turn out to be bursty.

**One NAT Gateway**
Cost decision. The only egress through the NAT is the enrich task calling an external API. Everything else — S3, KMS, Secrets Manager, ECR, CloudWatch Logs — goes through VPC endpoints and never touches the NAT. One NAT is fine for this traffic pattern. If we were running high-volume egress across all tasks we'd revisit it.

**Secrets Manager over SSM Parameter Store**
Both would work. Secrets Manager is the right semantic for credentials — it's built for rotation, it's what ECS task secrets expects, and it makes the intent clear to anyone reading the Terraform later.

**SNS over SES for notifications**
SES would work for email but that's all it does. SNS fans out to email, Slack, PagerDuty, or anything else with a subscription — without touching the pipeline code. Worth the marginal extra setup.

**Cross-region S3 replication to eu-central-1 for DR**
Cheap insurance at around $0.02/GB. Frankfurt is still EU so data residency isn't compromised. I am not replicating RDS cross-region — there's no defined RTO requirement that would justify Aurora Global DB costs.

---

## 6. Trade-offs

> I didn't make these calls lightly. Here's the honest version of each one.

**Single NAT Gateway**
I went with one NAT instead of one-per-AZ. The only thing routing through it is the enrich task calling an external API — if that NAT goes down, enrich fails until it recovers, but nothing else is affected. For this workload that's acceptable. If the enrich SLA ever gets formalised or that vendor becomes business-critical, adding a second NAT is a five-minute Terraform change. We'll revisit it then.

**No CloudFront or Transfer Acceleration**
Stockholm users uploading to a Stockholm bucket — the latency is already fine. I didn't want to add CloudFront complexity for a problem we don't have yet. If the user base ever goes beyond Sweden, i will add it. Until then it's unnecessary overhead.

**No WAF**
This one i am less comfortable with. The API is currently exposed without rate limiting or request filtering. It needs WAF before this goes anywhere near production. I flagged it, i haven't forgotten it — it just wasn't in scope for this design exercise.

**No Auth in the Terraform**
Same story. The endpoints are unauthenticated in the current design. Cognito or a Lambda authorizer needs to go in before launch. This is the highest risk item on the list and everyone on the team knows it.

**`force_destroy` and `skip_final_snapshot`**
Both are set to true right now for convenience in dev and staging. Flip them to false before production. If someone forgets and runs `terraform destroy` in prod, there's no coming back from that without the S3 DR copy — which is exactly why the cross-region replication exists.

---

## 7. GDPR / PII Posture

Company is Stockholm-based, so GDPR isn't optional — it shaped several decisions from the start rather than being bolted on at the end.

**Encryption everywhere.** KMS CMK across the board — S3 uploads bucket, processed bucket, RDS, DynamoDB, SNS, CloudWatch Logs, Secrets Manager. It's slightly more operational overhead than SSE-S3 but there's no real argument for cutting corners on a PII workload. Customer-managed keys mean we control rotation and can audit key usage independently.

**Don't keep PII longer than you need it.** The raw uploads bucket has a 1-day lifecycle expiry. Once the scrub task has run, the original file is gone. We're not in the business of hoarding raw PII on S3.

**Least privilege per task.** Each Fargate task has its own IAM role scoped to only the S3 prefix it actually needs. The scrub task can't read the enriched output. The load task can't touch the uploads bucket. If one task is compromised, the blast radius stays contained.

**Audit trail.** CloudTrail data events are on for the uploads bucket. We know who put what, when.

**Secrets handled properly.** DB password and the external API key live in Secrets Manager. They're injected as ECS task secrets at runtime — not baked into environment variables, not hardcoded anywhere. Auto-rotation is available when we're ready to enable it.

**Data residency.** Everything stays in eu-north-1. The DR replication goes to eu-central-1 (Frankfurt) which is still EU — no data leaves the region bloc.

**The one thing i can't fully control from infrastructure:** If the enrichment vendor is US-based, we have a Schrems II exposure. The pipeline is already structured correctly — scrub runs before enrich, so PII is removed before anything leaves our environment. But this needs a legal review and a proper DPA with the vendor. Infrastructure can only do so much here.

---

## 8. Deployment & CI/CD

All infrastructure is managed via Terraform. Deployments can run through an AWS CodeBuild pipeline or GithubAction piepline triggered on merge to `main` — `terraform init`, `terraform plan`, `terraform apply` in sequence. Terraform state lives in an S3 backend with versioning enabled and a DynamoDB lock table to prevent concurrent applies.

```
GitHub / CodeCommit (main branch)
        │
        ▼ on merge
   AWS CodeBuild / Github Actioin
        │
        ├── terraform init
        ├── terraform plan
        └── terraform apply
               │
               ▼
        AWS Infrastructure (eu-north-1)
```

There's no manual approval gate between plan and apply right now. For production we should add one — a human should be reviewing the plan output before anything applies to prod.

---

## 9. Open Items

These are the things i haven't resolved yet. Some are well-understood and just need time. A few are genuinely uncertain.

**Must be done before production:**
- **Auth on the API** — No Cognito, no Lambda authorizer in the current Terraform. This is a blocker for prod.
- **WAF** — API is unprotected. Add rate limiting and basic request filtering before production launch.
- **Flip the destroy flags** — `force_destroy = false` and `skip_final_snapshot = false` on all prod resources. Easy change, easy to forget under pressure.
- **Manual approval gate in CodeBuild** — Plan output should be reviewed by a human before applying to production.

**Needs external input:**
- **Schrems II / enrichment vendor** — We don't know yet if the enrichment vendor processes data in the US. If they do, the scrub task must strip all PII before the enrich task runs — the pipeline order already enforces this, but we need legal and the vendor's DPA reviewed before you go live. 

**Worth watching, not urgent:**
- **Concurrent upload load testing** — I've assumed 20 concurrent uploads. It needs validating against real Fargate task concurrency limits and RDS connection behaviour before YOU see real traffic.
- **Aurora Serverless v2** — i went with RDS Postgres Multi-AZ because write patterns aren't clear yet. If post-launch metrics show bursty writes, Aurora Serverless v2 is the natural next step. Worth a conversation after the first month in prod.
- **One NAT per AZ** — Low priority right now. Revisit if enrich SLA gets formalised.
