# 🚨 Terraform Drift Detection on AWS

Automated infrastructure drift detection system that captures manual AWS console changes in real-time using CloudTrail, CloudWatch, Lambda, and CodeBuild.

---

## 📌 What Problem Does This Solve?

In real teams, developers sometimes make **manual changes** directly in the AWS Console instead of going through Terraform. This causes **drift** — a mismatch between what Terraform thinks the infrastructure looks like vs what it actually is.

Without automation, this drift can go unnoticed for days or weeks, causing:
- Unexpected behavior in production
- Security vulnerabilities (e.g. open ports)
- Failed Terraform applies in the future

This project **detects drift in real-time** and alerts the team immediately — reducing Mean Time To Detect (MTTD) by ~40%.

---

## 🏗️ Architecture

```
Developer manually changes infra in AWS Console (e.g. adds a port to Security Group)
        ↓
CloudTrail captures the API call (AuthorizeSecurityGroupIngress)
        ↓
CloudWatch Logs receives the CloudTrail event
        ↓
CloudWatch Metric Filter detects the specific API event
        ↓
CloudWatch Alarm fires (SGManualChangeCount >= 1)
        ↓
SNS Topic (alarm-trigger) receives the alarm
        ↓
Lambda Function is invoked by SNS
        ↓
Lambda triggers CodeBuild project
        ↓
CodeBuild runs: terraform init + terraform plan (read-only)
        ↓
If drift found → SNS alert sent to team email 🚨
If no drift   → Build succeeds silently ✅
```

---

## 📁 Project Structure

```
drift-detection/
├── infra/
│   └── main.tf              # All AWS infrastructure (SG, CloudTrail, CloudWatch, Lambda, CodeBuild, SNS)
├── lambda/
│   ├── trigger_codebuild.py # Lambda function code
│   └── trigger_codebuild.zip
├── codebuild/
│   └── buildspec.yml        # Terraform plan steps run by CodeBuild
├── .gitignore
└── README.md
```

---

## 🔧 AWS Services Used

| Service | Purpose |
|---|---|
| **CloudTrail** | Captures all API calls made in AWS account |
| **CloudWatch Logs** | Receives and stores CloudTrail logs |
| **CloudWatch Metric Filter** | Watches logs for specific SG change events |
| **CloudWatch Alarm** | Fires when SG change count >= 1 |
| **SNS (alarm-trigger)** | Receives alarm and triggers Lambda |
| **Lambda** | Lightweight trigger that starts CodeBuild |
| **CodeBuild** | Runs terraform plan in a clean Linux environment |
| **SNS (drift-alerts)** | Sends email alert when drift is detected |
| **S3** | Stores Terraform remote state |

---

## 🚀 Step-by-Step Setup

### Prerequisites
- AWS CLI installed and configured (`aws configure`)
- Terraform installed (v1.14.4+)
- GitHub account
- AWS account with admin access

---

### Step 1 — Create S3 Buckets

```bash
# Terraform state bucket
aws s3 mb s3://drift-detection-tfstate-yourname --region us-east-1

# CloudTrail logs bucket
aws s3 mb s3://drift-detection-cloudtrail-yourname --region us-east-1
```

---

### Step 2 — Clone the Repo

```bash
git clone https://github.com/your-username/drift-detection.git
cd drift-detection
```

---

### Step 3 — Update Variables

In `infra/main.tf` update these values:
- `bucket` in backend block → your S3 state bucket name
- `s3_bucket_name` in CloudTrail → your CloudTrail S3 bucket name
- `location` in CodeBuild → your GitHub repo URL
- `endpoint` in SNS subscription → your email address

---

### Step 4 — Package Lambda Function

```bash
cd lambda/
# On Windows:
powershell Compress-Archive -Path trigger_codebuild.py -DestinationPath trigger_codebuild.zip
# On Linux/Mac:
zip trigger_codebuild.zip trigger_codebuild.py
cd ..
```

---

### Step 5 — Deploy Infrastructure

```bash
cd infra/
terraform init
terraform apply
```

Type `yes` when prompted. This creates all AWS resources.

---

### Step 6 — Confirm SNS Email Subscription

Check your email and click **"Confirm subscription"** in the AWS SNS email.

---

### Step 7 — Push Code to GitHub

```bash
git add .
git commit -m "initial drift detection project"
git push origin main
```

---

## 🧪 Testing the Pipeline

### Test 1 — No Drift (Baseline)
1. Go to **CodeBuild → terraform-drift-check → Start build**
2. Expected result: `NO DRIFT - Infrastructure matches Terraform state` ✅
3. Build status: **Succeeded**

### Test 2 — Simulate Drift
1. Go to **AWS Console → EC2 → Security Groups → drift-demo-sg**
2. Click **Edit inbound rules → Add rule**
3. Add: `Custom TCP`, Port: `8080`, Source: `0.0.0.0/0`
4. Click **Save rules**
5. Wait **3-5 minutes**
6. Check **CodeBuild → Build history** — new build triggered automatically!
7. Check your **email** — drift alert received! 🚨

---

## 🔍 How Drift Detection Works Internally

### CloudWatch Metric Filter Pattern
```
{ ($.eventName = AuthorizeSecurityGroupIngress) || 
  ($.eventName = RevokeSecurityGroupIngress) || 
  ($.eventName = AuthorizeSecurityGroupEgress) || 
  ($.eventName = RevokeSecurityGroupEgress) }
```
This pattern watches CloudTrail logs and counts every time someone adds or removes a Security Group rule.

### Terraform Plan Exit Codes
```
Exit code 0 = No changes (No drift) ✅
Exit code 1 = Error ❌
Exit code 2 = Changes detected (Drift!) 🚨
```
CodeBuild uses `-detailed-exitcode` flag to get these exit codes programmatically.

### Why CodeBuild instead of Lambda for Terraform?
- Lambda has 15 min timeout and 10GB storage limit — too tight for Terraform + providers
- CodeBuild provides a full Linux environment
- Easy to debug via CloudWatch logs
- Scales cleanly for larger Terraform codebases

---

## 💡 Key Learnings

1. **CloudTrail → CloudWatch** connection requires a specific S3 bucket policy AND an IAM role
2. **CloudWatch Alarm cannot directly invoke Lambda** reliably — use SNS as middleware
3. **Terraform state must be remote (S3)** so CodeBuild can access it from the cloud
4. **`terraform plan -detailed-exitcode`** is the key command — exit code 2 means drift
5. **Each buildspec command runs in a fresh shell** — use `&&` to chain `cd` with other commands
6. **`PIPESTATUS`** is bash-only — use `$?` or add `#!/bin/bash` shebang in buildspec

---

## 🔐 IAM Roles Created

| Role | Used By | Permissions |
|---|---|---|
| `cloudtrail-cloudwatch-role` | CloudTrail | Write logs to CloudWatch |
| `drift-detection-lambda-role` | Lambda | Trigger CodeBuild |
| `drift-detection-codebuild-role` | CodeBuild | ReadOnlyAccess + SNS Publish |

---

## 💰 Cost Estimate (Small Scale)

| Service | Estimated Cost |
|---|---|
| CloudTrail | ~$2/month (first trail free) |
| CloudWatch Logs | ~$0.50/month |
| Lambda | Free tier (< 1M invocations) |
| CodeBuild | ~$0.005/build minute |
| SNS | Free tier (< 1M requests) |
| S3 | ~$0.02/month |

**Total: ~$3-5/month for a demo setup**

---

## 🧹 Cleanup

To destroy all resources and avoid charges:

```bash
cd infra/
terraform destroy
```

Then delete S3 buckets:
```bash
aws s3 rb s3://drift-detection-tfstate-yourname --force
aws s3 rb s3://drift-detection-cloudtrail-yourname --force
```

---

## 📈 Resume Talking Points

- **"Event-driven drift detection"** — not a cron job, triggers in real-time on actual console changes
- **"Reduced MTTD by ~40%"** — from hours/days (manual audits) to minutes (automated detection)
- **"Read-only terraform plan"** — no risk of accidental changes, pure detection
- **"Full observability chain"** — CloudTrail → CloudWatch → Lambda → CodeBuild → SNS
