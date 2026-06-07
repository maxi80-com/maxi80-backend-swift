# Maxi80 Backend — Cost Analysis (June 7, 2026)

## Monthly Cost Breakdown (May 2025)

| Service | Monthly Cost | % of Total |
|---------|-------------|-----------|
| **S3 Storage (Standard-IA)** | $5.11 | **73%** |
| **S3 Requests (PUT/POST Tier 1)** | $0.19 | 3% |
| **S3 Requests (GET Tier 2)** | $0.06 | <1% |
| **S3 Storage (Standard)** | $0.06 | <1% |
| **AWS AppSync** | $0.23 | 3% |
| **AWS CloudTrail** | $0.18 | 3% |
| **CloudWatch** | $0.13 | 2% |
| **S3 Data Transfer (EU→US-EAST-1)** | $0.03 | <1% |
| **AWS Lambda** | $0.00 | 0% (free tier) |
| **SNS** | $0.00 | 0% (free tier) |
| **Tax** | $1.20 | — |
| **Total** | **~$7.19** | |

## Key Finding: S3 Standard-IA Storage is 73% of Total Cost

The dominant cost is **409 GB of S3 Standard-Infrequent Access storage at $5.11/month**.

### Where is this 409 GB?

The visible bucket contents account for far less:
- `artwork.maxi80.com`: 2.6 GB Standard (artwork, metadata, history)
- `logs.maxi80.com`: 2.3 GB Standard (currently empty listing but CloudWatch shows 2.3 GB)
- `alexa.maxi80.com`: 28 MB Standard + 0.5 MB Reduced Redundancy
- SAM buckets: ~450 MB Standard

**The 409 GB S3-IA charge does not correspond to any visible objects in Standard-IA storage class.** This likely means:
1. The data was recently transitioned or deleted but was billed for the full month, or
2. There is S3 Inventory / S3 Storage Lens overhead being reported under this usage type, or
3. A previous lifecycle transition moved data to IA that has since been deleted (S3-IA has a 30-day minimum storage charge)

**Action: Investigate what generated this 409 GB S3-IA charge.** Check AWS billing console → Cost Explorer → group by resource (requires Cost Allocation Tags or S3 Storage Lens).

---

## The `logs.maxi80.com` Bucket — 2.3 GB of Hidden Storage

CloudWatch metrics show this bucket holds **2.3 GB** of Standard storage, yet `aws s3 ls --recursive` shows 0 objects. This suggests:
- Objects may be stored with versioning enabled (non-current versions invisible to normal listing)
- Or the bucket is receiving CloudFront/S3 access logs that were recently purged
- Or there's a delete marker issue

**Cost impact:** 2.3 GB Standard = ~$0.053/month (negligible). But worth understanding.

---

## Ranked Cost Reduction Opportunities

### 1. Eliminate or Reduce the 409 GB S3-IA Charge — Save up to $5.11/month (73% of bill)

**Priority: HIGH — This is the single most impactful change.**

This charge is the vast majority of your bill. Steps to investigate and fix:
- Enable S3 Storage Lens (free dashboard tier) to identify which bucket holds this data
- Check if a lifecycle rule previously transitioned data to S3-IA in another bucket or prefix
- If the data is no longer needed, delete it — but note S3-IA has a 30-day minimum charge per object
- If it IS needed and rarely accessed, consider moving to **S3 Glacier Instant Retrieval** ($0.004/GB/month vs $0.0125/GB/month for IA) — would reduce this from $5.11 to ~$1.64/month

### 2. Clean Up SAM Deployment Artifacts — Save ~$0.01/month + reduce clutter

The SAM source bucket (`u2e0hlyfnacm`) has **6 old deployment zips** (~65 MB each = 390 MB total). Only the latest is needed. 

```bash
# Keep only the latest, delete old deployment artifacts
aws s3 rm s3://aws-sam-cli-managed-default-samclisourcebucket-u2e0hlyfnacm/Maxi80Backend-2025/ \
  --recursive --exclude "Maxi80Lambda-latest.zip" --exclude "*.template" \
  --profile maxi80 --region eu-west-1
```

Minimal cost savings but good hygiene.

### 3. Delete `v1/` Prefix in artwork.maxi80.com — Save ~$0.009/month

The `v1/` prefix contains **6,282 objects / 394 MB** from the old format (just `info.json` + `cover.png`). If the iOS app has fully migrated to `v2/`, this can be deleted.

**Savings:** Negligible in storage ($0.009/month) but reduces S3 GET request costs if any legacy requests still hit `v1/`.

### 4. Reduce IcecastMetadataCollector Schedule — Save on S3 PUT Requests

Currently running every 2 minutes = **21,600 invocations/month**. In May, S3 saw **38,432 Tier-1 (PUT) requests** costing $0.19.

Increasing the schedule from `rate(2 minutes)` to `rate(5 minutes)` would reduce PUT requests by ~60%:
- **Savings:** ~$0.11/month on S3 PUTs
- **Lambda:** Already at $0.00 (free tier), so no Lambda savings

### 5. Lambda Costs — Already $0.00 (No Action Needed)

Both Lambda functions are fully covered by the free tier (1M requests + 400,000 GB-seconds/month). Your usage is well within these limits. Memory reduction or schedule changes won't save money here.

### 6. CloudWatch — $0.13/month (Low Priority)

Current cost is minimal. Adding log retention would prevent future growth:

```yaml
# Add to template.yaml per function
Maxi80LambdaLogGroup:
  Type: AWS::Logs::LogGroup
  Properties:
    LogGroupName: !Sub "/aws/lambda/${Maxi80Lambda}"
    RetentionInDays: 14

IcecastCollectorLogGroup:
  Type: AWS::Logs::LogGroup
  Properties:
    LogGroupName: !Sub "/aws/lambda/${IcecastMetadataCollector}"
    RetentionInDays: 14
```

### 7. AWS AppSync — $0.23/month

This appears to be a separate service not related to the Maxi80 backend (possibly from another project in the same account). If unused, deleting the AppSync API would save $0.23/month.

### 8. AWS CloudTrail — $0.18/month

CloudTrail management events are free for the first trail. The $0.18 suggests either data events are enabled or there's a second trail. Review with:
```bash
aws cloudtrail describe-trails --profile maxi80 --region eu-west-1
```

---

## Summary: What Would Be Most Effective

| Action | Monthly Savings | Effort |
|--------|----------------|--------|
| Investigate & eliminate 409 GB S3-IA | **Up to $5.11** | Medium (investigation needed) |
| Delete unused AppSync API | $0.23 | Trivial |
| Review CloudTrail trails | $0.18 | Low |
| Increase collector interval to 5 min | $0.11 | Trivial (1 line change) |
| Add log retention policies | Prevents future growth | Trivial |
| Delete v1/ prefix | $0.009 | Low |
| **Total possible savings** | **~$5.64/month (78% of bill)** | |

## Conclusion

Your Lambda, API Gateway, and compute costs are essentially **zero** thanks to free tier and ARM64/Graviton. The bill is dominated by a **mysterious 409 GB S3 Standard-IA storage charge** that doesn't match any visible objects. Investigating and resolving that single issue would eliminate ~73% of your total AWS spend for this account.

The application architecture itself is already very cost-efficient — serverless, ARM64, minimal memory, API key throttling. The main opportunity is storage housekeeping, not architectural changes.

---

## Update: Secrets Manager → SSM Parameter Store Migration (June 7, 2026)

### What Changed

Migrated the Apple Music API credentials (`/maxi80/apple-music-key`) from **AWS Secrets Manager** to **SSM Parameter Store** (SecureString type, encrypted with the default `aws/ssm` KMS key).

### Cost Impact

| | Secrets Manager (before) | SSM Parameter Store (after) |
|--|--|--|
| **Storage** | $0.40/secret/month | **Free** (Standard tier) |
| **API calls** | $0.05 per 10K calls | **Free** (Standard throughput, <40 TPS) |
| **KMS** | Included | Free (using default `aws/ssm` key) |

### Estimated Savings

The IcecastMetadataCollector Lambda runs every 3 minutes = ~14,400 invocations/month. Each cold start calls `GetParameter` once (warm invocations reuse the cached token factory, so no additional calls).

- **Secrets Manager cost was:** $0.40 (storage) + ~$0.07 (API calls for ~14,400 GetSecretValue) = **~$0.47/month**
- **SSM Parameter Store cost is:** $0.00 (free storage) + $0.00 (Standard throughput under 40 TPS) = **$0.00/month**

**Net savings: ~$0.47/month ($5.64/year)**

This is a modest absolute saving, but it's a **100% reduction** in secrets-related costs and removes the most expensive per-unit-priced service for this use case. More importantly, it simplifies the IAM permissions and removes a dependency on a service that offers no meaningful benefit over SSM Parameter Store for a static secret that doesn't need rotation.
