# Runbook — API metrics, throttling and edge caching

Status: **Baseline captured 2026-08-21**, pre-launch. Re-run §2 after the app
launch / social-media push and revisit §3 and §4 with the new numbers.

Audience: whoever sizes protection for the Maxi80 HTTP API. Every command below
is copy-pasteable and read-only.

Context: this runbook came out of chasing a KMS line item on the bill. The KMS
cost turned out to be a symptom — the authorizer had no result caching, so it ran
on every request and cold-started ~3k times a day, and each cold start paid one
SSM `GetParameter` + one KMS `Decrypt` for `/maxi80/api-key`. The fix was
`ReauthorizeEvery: 3600` in `template.yaml` (deployed 2026-08-21). The lesson
worth keeping: **the service you get billed for is often not the service you
configure.**

---

## 1. Baseline (pre-launch, measured 2026-08-08 → 2026-08-21)

Compare against these after launch.

| Metric | Value |
|---|---|
| API requests | ~13,800–15,000 / day |
| Peak minute | 458 requests (7.63 rps averaged over that minute) |
| p99 minute | 206 requests (3.43 rps) |
| Median minute | 7 requests (0.12 rps) |
| Minutes with zero traffic | ~69% |
| `Maxi80Lambda` cold starts | 3,721 / day (25% of invocations) |
| `AuthorizerLambda` cold starts | 3,066 / day (pre-caching) |
| Authorizer : Maxi80Lambda invocations | 1 : 1 (pre-caching) |
| KMS requests, eu-central-1 | ~3,284 / day, ~74% `alias/aws/ssm` |
| KMS cost | ~$0.25 / month projected |
| Total bill (July 2026) | ~$1.00 |

The 69% figure matters more than it looks: traffic arrives in **clumps**, not a
steady stream. Minute-averages therefore understate the instantaneous rate, and
CloudWatch cannot go below 60s to tell you by how much. Size burst limits
accordingly.

---

## 2. How to re-measure

All commands assume `--profile maxi80`. API id is `m0fjchl4pk`; re-resolve it
with `aws apigatewayv2 get-apis` if the stack is ever recreated.

### 2.1 Request rate distribution — the input for throttle sizing

Daily totals are useless for sizing; you need the peak. This pulls 1-minute
buckets and prints percentiles. Adjust `days` after launch.

```bash
python3 - <<'EOF'
import subprocess, json, datetime, statistics
days = 13
end = datetime.datetime.now(datetime.UTC); start = end - datetime.timedelta(days=days)
q = [{"Id":"c","MetricStat":{"Metric":{"Namespace":"AWS/ApiGateway","MetricName":"Count",
     "Dimensions":[{"Name":"ApiId","Value":"m0fjchl4pk"}]},"Period":60,"Stat":"Sum"}}]
open("/tmp/q.json","w").write(json.dumps(q))
vals, token = [], None
while True:
    a = ["aws","cloudwatch","get-metric-data","--profile","maxi80","--region","eu-central-1",
         "--metric-data-queries","file:///tmp/q.json","--output","json",
         "--start-time",start.strftime("%Y-%m-%dT%H:%M:%SZ"),
         "--end-time",end.strftime("%Y-%m-%dT%H:%M:%SZ")] + (["--next-token",token] if token else [])
    r = json.loads(subprocess.run(a,capture_output=True,text=True,check=True).stdout)
    vals += r["MetricDataResults"][0]["Values"]; token = r.get("NextToken")
    if not token: break
s = sorted(vals); pct = lambda p: s[min(len(s)-1,int(len(s)*p/100))]
print("populated minutes:", len(s), "of", days*1440)
for lbl, v in [("median",statistics.median(s)),("p95",pct(95)),("p99",pct(99)),
               ("p99.9",pct(99.9)),("max",max(s))]:
    print(f"  {lbl:7s} {v:7.0f} req/min   {v/60:6.2f} rps")
EOF
```

### 2.2 Cold starts

Lambda has no cold-start metric. The functions log in JSON format
(`LoggingConfig.LogFormat: JSON` in `template.yaml`), so cold starts are the
records carrying `record.metrics.initDurationMs`. Note this is **not** the
`Init Duration` text pattern — that only matches plain-text log format and will
silently return zero rows here.

```bash
aws logs start-query --profile maxi80 --region eu-central-1 \
  --log-group-names /aws/lambda/<AuthorizerFn> /aws/lambda/<Maxi80Fn> \
  --start-time $(date -v-1d +%s) --end-time $(date +%s) \
  --query-string 'filter ispresent(record.metrics.initDurationMs) | stats count(*) as coldStarts by @log'
# then: aws logs get-query-results --query-id <id>
```

Resolve the function names with
`aws lambda list-functions --query 'Functions[].FunctionName'`.

### 2.3 Is the authorizer cache working?

Compare invocation counts. Pre-caching they were 1:1. The authorizer should now
be a small fraction of `Maxi80Lambda`.

```bash
for fn in <AuthorizerFn> <Maxi80Fn>; do
  echo "=== $fn ==="
  aws cloudwatch get-metric-statistics --profile maxi80 --region eu-central-1 \
    --namespace AWS/Lambda --metric-name Invocations \
    --dimensions Name=FunctionName,Value=$fn \
    --start-time 2026-08-21T00:00:00Z --end-time 2026-08-28T00:00:00Z \
    --period 86400 --statistics Sum \
    --output text --query 'Datapoints[].[Timestamp,Sum]' | sort
done
```

Confirm the live TTL survived the last deploy:

```bash
aws apigatewayv2 get-authorizers --profile maxi80 --region eu-central-1 \
  --api-id m0fjchl4pk --query 'Items[].{TTL:AuthorizerResultTtlInSeconds}'
```

### 2.4 Attributing a KMS bill

Two steps. First the cost and volume by region and usage type:

```bash
aws ce get-cost-and-usage --profile maxi80 --region us-east-1 \
  --time-period Start=2026-08-01,End=2026-09-01 \
  --granularity MONTHLY --metrics UnblendedCost UsageQuantity \
  --filter '{"Dimensions":{"Key":"SERVICE","Values":["AWS Key Management Service"]}}' \
  --group-by Type=DIMENSION,Key=REGION Type=DIMENSION,Key=USAGE_TYPE
```

Then attribute the requests. The **encryption context is what identifies the
caller**, so read it rather than guessing:

- `PARAMETER_ARN=...` → SSM decrypting a SecureString for you
- `aws:lambda:FunctionArn=...` → the Lambda service decrypting that function's
  environment variables at init. Unavoidable while the function has any env
  vars, and it is the floor on your KMS bill.

```bash
aws cloudtrail lookup-events --profile maxi80 --region eu-central-1 \
  --lookup-attributes AttributeKey=EventSource,AttributeValue=kms.amazonaws.com \
  --start-time 2026-08-20T10:00:00Z --end-time 2026-08-20T11:00:00Z \
  --query 'Events[].CloudTrailEvent' --output json
```

Pick a **one-hour** window and paginate fully. Wider windows hit
`ThrottlingException` and truncate silently, which skews the attribution.

Useful facts to avoid a repeat investigation: the account has **no
customer-managed keys**, so there is no $1/key/month charge — every KMS cent is
API requests at $0.03/10,000 with 20,000 free per month. `alias/aws/s3` and
`alias/aws/secretsmanager` are orphaned AWS-managed keys; they cannot be deleted
and cost nothing.

---

## 3. Sizing throttling

HTTP APIs **do** support throttling, at stage and per-route level. What is
REST-only is usage plans, API keys and WAF — that is the usual source of the
"HTTP API can't throttle" confusion.

Stage-wide, declaratively, in `template.yaml` under `Maxi80HttpApi`:

```yaml
DefaultRouteSettings:
   ThrottlingRateLimit: 100
   ThrottlingBurstLimit: 200
```

SAM passes `DefaultRouteSettings` straight through to `RouteSettings` on the
`AWS::ApiGatewayV2::Stage`. Per-route limits need the CLI or SDK.

**The sizing formula.** API Gateway uses a token bucket: `ThrottlingRateLimit`
is the refill rate, `ThrottlingBurstLimit` the capacity. Requests servable in a
window of T seconds ≈ `burst + rate × T`. Take your worst observed minute from
§2.1 and check it survives being compressed into a few seconds. With the
pre-launch peak of 458 req/min, 200/100 holds even if all 458 land inside 3
seconds (200 + 300 = 500). 100/50 would need them spread over 8s, which the 69%
idle-minute clumping makes optimistic.

**Recommended pre-launch value: rate 100, burst 200.** Not applied yet — the
account default of 10,000 rps is still in effect.

**Why bother.** This is a cost circuit-breaker, not capacity planning. At 100 rps
sustained for a day (8.64M requests): ~$8.60 API Gateway, ~$1.70 Lambda
invocations, ~$0.70 duration, up to ~$3.50 S3 GETs — roughly $14/day. On the
account default of 10,000 rps the same math is ~$1,450/day. The exact number
matters far less than having one.

**Two limitations, both real.** Stage throttling is a single global bucket, not
per-client, so one abuser saturating it throttles real users too — it converts a
cost problem into an availability problem. And I could not confirm from official
HTTP API docs whether throttled 429s are themselves billable (the "they're free"
claim I found is community-sourced and scoped to REST APIs), so treat the $14/day
as an estimate, not a ceiling.

After launch, re-run §2.1 and re-derive. Do not carry the 100/200 forward
blindly — if real peaks land near 100 rps you will be serving 429s to genuine
listeners.

---

## 4. CloudFront — better than throttling, when there's traffic to justify it

Worth more than any rate limit, because the payloads are near-static:

- `GET /station` returns `Station.default` — a **compile-time constant** in
  `Sources/Maxi80Backend/Station.swift`, varied only by the `FEATURE_FLAGS` env
  var. It does not need to reach Lambda at all.
- `GET /history` reads `history.json`, rewritten at most every 3 minutes
  (`IcecastMetadataCollector` runs on `rate(3 minutes)`).
- `GET /artwork` returns a presigned S3 URL. **Do not cache this naively** — the
  URL expires per `URL_EXPIRATION` (3600s), so any TTL must stay comfortably
  below it, and the cache key must include the `artist` and `title` query
  strings.

Suggested starting TTLs: `/station` 300s, `/history` 60s, `/artwork` either
uncached or well under the presign expiry with query strings in the cache key.

What this buys, in rough order of value:

1. Cost collapses. A cache hit costs CloudFront request pricing and skips API
   Gateway, Lambda and S3 entirely. At the ratios above most traffic becomes
   hits, and CloudFront's free tier (1 TB out, 10M requests/month) likely
   absorbs the whole workload.
2. Abuse gets much cheaper to absorb, because hits never reach your account's
   billable path.
3. **WAF becomes available**, which is the only route to genuine per-client rate
   limiting on this stack. That is the real fix for the §3 global-bucket
   limitation.
4. Latency improves for listeners outside eu-central-1.

Costs to weigh: a second CDN hop for cache misses, staleness bounded by TTL, and
one more thing to invalidate when the station metadata changes. Also, the
`Authorization` header must be forwarded, or every request will look identical to
CloudFront and the authorizer will never see the key.

**Decision point.** Not worth building at 15,000 requests/day — the current bill
is ~$1/month and CloudFront would add complexity for pennies. Revisit if launch
pushes sustained traffic above roughly 100k requests/day, or the moment you need
per-client rate limiting.

---

## 5. Unrelated finding worth fixing

`Maxi80Lambda` cold-starts 3,721 times a day on ~15,000 invocations — a 25%
cold-start rate. That is a latency problem for listeners and costs more in Lambda
duration than the entire KMS line item this runbook started with.
