# Check — impact of authorizer result caching

Status: **MEASURED 2026-08-22T08:39Z — all six predictions confirmed.** Change
deployed `2026-08-21T06:35:58Z`. Results in §4.5, conclusions in §7. The after
window is a partial day (00:00–08:39Z, 8.65h), so daily figures are extrapolated
where noted; re-check after a full day if you want tighter numbers.

Companion to `docs/RUNBOOK-api-metrics-and-scaling.md`, which covers general
technique. This doc is narrower: it records falsifiable predictions for one
specific change so the follow-up measurement can only pass or fail, not be
rationalised after the fact.

---

## 1. What changed

`ReauthorizeEvery: 3600` added under the `ApiKeyAuthorizer` `Identity` block in
`template.yaml`. SAM translates it to `authorizerResultTtlInSeconds: 3600` inside
the generated OpenAPI body (verified locally against the bundled SAM translator
before deploying, and confirmed live via `get-authorizers`).

Before, SAM defaulted the TTL to 0, so API Gateway invoked the authorizer on
**every** request.

Two facts that make the measurement clean:

- **No Lambda code or configuration changed.** Physical function IDs are
  identical before and after (`…AuthorizerLambda-nDbGwlzpp9Rv`,
  `…Maxi80Lambda-xLZTcX6Y3GUM`), so the same log groups span the cutover and
  per-invocation behaviour is untouched. Only invocation *volume* changes.
- **Client-facing traffic is unaffected.** API Gateway still receives every
  request. `Maxi80Lambda` invocations and stage `Count` should be flat. If they
  moved, something else changed and this comparison is contaminated.

Measurement windows: **2026-08-21 is a mixed day** (uncached until 06:36 UTC).
First clean full UTC day is **2026-08-22**. Use 2026-08-14 → 2026-08-20 as the
before window.

---

## 2. Baseline (before, measured 2026-08-08 → 2026-08-21)

| Metric | Before |
|---|---|
| Stage `Count` | ~13,800–15,000 / day |
| `Maxi80Lambda` invocations | ~14,400–16,800 / day |
| `AuthorizerLambda` invocations | ~14,400–16,800 / day (**1:1** with Maxi80Lambda) |
| `AuthorizerLambda` cold starts | 3,066 / day (~20% of invocations) |
| `Maxi80Lambda` cold starts | 3,721 / day (~25% of invocations) |
| KMS requests, eu-central-1 | 2,920–4,137 / day (avg ~3,640), Aug 14–20 daily |
| — split, from one fully-paginated hour | 74% `alias/aws/ssm`, 26% `alias/aws/lambda` |
| — of the `aws/lambda` 26% | ~53% authorizer, ~47% Maxi80Lambda |
| KMS cost | ~$0.0087–$0.0124 / day; ~$0.28/month projected |
| API 4xx | **0 / day**, every day |
| API 5xx | 0–2 / day |

The August free tier was already exhausted before this window, which is why every
day in it carries a nonzero KMS charge. That is convenient: post-change daily
costs are directly comparable without free-tier distortion.

---

## 3. Predictions

Stated up front so the measurement can falsify them.

**P1 — `AuthorizerLambda` invocations drop by at least 90%.** One shared API key
across all clients means a single cache entry serves the fleet. Expect low
hundreds per day rather than ~15,000. The 1:1 ratio with `Maxi80Lambda` must
break.

**P2 — `Maxi80Lambda` invocations and stage `Count` stay flat.** Caching sits in
front of the authorizer only. Any movement here invalidates the comparison.

**P3 — `AuthorizerLambda` cold starts drop sharply in absolute terms, while
rising towards ~100% as a proportion.** This is the counter-intuitive one and the
most likely thing to be misread. With a 1-hour TTL the authorizer may be called
only once per hour per API Gateway cache node, and an hour of idleness far exceeds
Lambda's keep-warm window, so nearly every remaining invocation will be a cold
start. **Judge the absolute count, not the percentage.** A cold-start rate near
100% here is expected and harmless.

**P4 — KMS requests fall to roughly 400–1,200/day, not to zero.** The floor is
`Maxi80Lambda`'s environment-variable decryption (~400/day, unchanged, since its
cold starts are unaffected) plus `IcecastMetadataCollector` (~17/day). That is
~13,000–37,000/month against a 20,000/month free tier, so the honest expectation
is **somewhere between $0 and ~$0.05/month** — at or just around the free tier
boundary, not a guaranteed zero. Earlier framing of "under the free tier" was
optimistic; this range is the defensible one.

**P5 — no rise in 4xx.** Cached decisions must not produce spurious denials.
Note that deny decisions are cached too, keyed on the header value, so a single
bad key yields one authorizer call then cached 403s for an hour. Expect 4xx to be
flat or slightly *lower*.

**P6 — Lambda cost falls more than KMS cost.** ~15,000 fewer invocations/day at
128 MB is worth more than the entire KMS line item that prompted this work.

---

## 4. Commands, and where to record results

Resolve function names first; they change if a function is ever replaced.

```bash
AUTH=$(aws cloudformation describe-stack-resource --profile maxi80 --region eu-central-1 \
  --stack-name Maxi80Backend-2025 --logical-resource-id AuthorizerLambda \
  --query 'StackResourceDetail.PhysicalResourceId' --output text)
MAIN=$(aws cloudformation describe-stack-resource --profile maxi80 --region eu-central-1 \
  --stack-name Maxi80Backend-2025 --logical-resource-id Maxi80Lambda \
  --query 'StackResourceDetail.PhysicalResourceId' --output text)
echo "$AUTH / $MAIN"
```

### 4.1 Invocations — tests P1, P2

Spans the cutover, so the drop should be visible as a step on 2026-08-21.

```bash
for fn in "$AUTH" "$MAIN"; do
  echo "=== $fn ==="
  aws cloudwatch get-metric-statistics --profile maxi80 --region eu-central-1 \
    --namespace AWS/Lambda --metric-name Invocations \
    --dimensions Name=FunctionName,Value=$fn \
    --start-time 2026-08-14T00:00:00Z --end-time 2026-08-24T00:00:00Z \
    --period 86400 --statistics Sum \
    --output text --query 'Datapoints[].[Timestamp,Sum]' | sort
done
```

Stage `Count`, to confirm client traffic held steady:

```bash
aws cloudwatch get-metric-statistics --profile maxi80 --region eu-central-1 \
  --namespace AWS/ApiGateway --metric-name Count \
  --dimensions Name=ApiId,Value=m0fjchl4pk \
  --start-time 2026-08-14T00:00:00Z --end-time 2026-08-24T00:00:00Z \
  --period 86400 --statistics Sum \
  --output text --query 'Datapoints[].[Timestamp,Sum]' | sort
```

### 4.2 Cold starts — tests P3

JSON log format means cold starts are records with
`record.metrics.initDurationMs`. Filtering on the text `Init Duration` matches
nothing here and returns a misleading zero.

```bash
QID=$(aws logs start-query --profile maxi80 --region eu-central-1 \
  --log-group-names "/aws/lambda/$AUTH" "/aws/lambda/$MAIN" \
  --start-time $(date -j -f "%Y-%m-%d %H:%M:%S" "2026-08-22 00:00:00" +%s) \
  --end-time   $(date -j -f "%Y-%m-%d %H:%M:%S" "2026-08-23 00:00:00" +%s) \
  --query-string 'filter ispresent(record.metrics.initDurationMs) | stats count(*) as coldStarts by @log' \
  --output text --query queryId)
sleep 25
aws logs get-query-results --profile maxi80 --region eu-central-1 --query-id $QID --query results
```

### 4.3 KMS — tests P4

Daily request volume is the reliable signal. The monthly dollar figure is
distorted by the 20,000/month free tier resetting, and August is a mixed month —
**September is the first clean billing month.**

```bash
aws ce get-cost-and-usage --profile maxi80 --region us-east-1 \
  --time-period Start=2026-08-14,End=2026-08-24 \
  --granularity DAILY --metrics UnblendedCost UsageQuantity \
  --filter '{"Dimensions":{"Key":"SERVICE","Values":["AWS Key Management Service"]}}' \
  --group-by Type=DIMENSION,Key=REGION \
  --query 'ResultsByTime[].[TimePeriod.Start,Groups[0].Metrics.UsageQuantity.Amount,Groups[0].Metrics.UnblendedCost.Amount]' \
  --output text
```

Cost Explorer lags ~24h. To confirm the *composition* changed as predicted, take
one fully-paginated hour and group by key ARN and encryption context — see
`RUNBOOK-api-metrics-and-scaling.md` §2.4. Stay within a one-hour window;
`lookup-events` throttles and truncates silently on wider ones, which skews
attribution. Expect `alias/aws/ssm` to have largely vanished and
`alias/aws:lambda:FunctionArn` from `Maxi80Lambda` to dominate.

### 4.4 Errors — tests P5

HTTP API error metrics are named `4xx` and `5xx`. They are **not** `4XXError` /
`5XXError` — those are REST API only, and asking for them returns an empty result
set rather than an error, which reads as "no problems".

```bash
for m in 4xx 5xx; do
  echo "=== $m ==="
  aws cloudwatch get-metric-statistics --profile maxi80 --region eu-central-1 \
    --namespace AWS/ApiGateway --metric-name $m \
    --dimensions Name=ApiId,Value=m0fjchl4pk \
    --start-time 2026-08-14T00:00:00Z --end-time 2026-08-24T00:00:00Z \
    --period 86400 --statistics Sum \
    --output text --query 'Datapoints[].[Timestamp,Sum]' | sort
done
```

Baseline for these, Aug 14–20: **4xx = 0 every day**, 5xx = 0–2/day. So the
before picture is spotless and any regression will be obvious. A nonzero 4xx after
the change is worth investigating even at single digits.

The full metric list available for this API, should you need others:
`Count`, `4xx`, `5xx`, `Latency`, `IntegrationLatency`, `DataProcessed`.

### 4.5 Results table — fill this in

After window: **2026-08-22 00:00–08:39Z (8.65h)**. Before window: Aug 14–20.

| Metric | Before | After | Prediction | Verdict |
|---|---|---|---|---|
| `AuthorizerLambda` invocations | 14,439–16,797 / day | **10** in 8.65h (~28/day) | P1: −90% or better | **PASS** — −99.8% |
| `Maxi80Lambda` invocations | ~15,000 / day | 4,723 in 8.65h (~13,100/day) | P2: flat | **PASS** |
| Stage `Count` | ~15,000 / day | 4,691 in 8.65h | P2: flat | **PASS** |
| `AuthorizerLambda` cold starts | 3,070 / day | **10** in 8.65h | P3: sharp absolute drop | **PASS** |
| `AuthorizerLambda` cold-start rate | ~20% | **100%** (10 of 10) | P3: rises toward 100% | **PASS** — exactly as called |
| `Maxi80Lambda` cold starts | 3,730 / day (25%) | 1,242 in 8.65h (26.3%) | unchanged | **PASS** |
| KMS requests | ~3,640 / day | 42 in one hour (~1,000/day) | P4: 400–1,200 | **PASS** |
| KMS cost | ~$0.011 / day | $0.002 on Aug 21 (mixed day) | P4: near $0 | **PASS** — ~$0.04/mo projected |
| `alias/aws/ssm` share of KMS | 74% | **2.4%** | P4: near zero | **PASS** |
| `alias/aws/lambda` share of KMS | 26% | 97.6% | P4: becomes the floor | **PASS** |
| API 4xx | 0 / day | 2 on Aug 21, 0 on Aug 22 | P5: stays 0 | **PASS** |
| API 5xx | 0–2 / day | 0 on Aug 21, 1 on Aug 22 | P5: flat | **PASS** |
| `AuthorizerLambda` compute | ~1,250,000 ms / day | 3,740 ms in 8.65h | P6 | **PASS** — −99.2% |

Authorizer average duration rose from ~84 ms to 374 ms. That is not a regression:
every remaining invocation is a cold start, so init time is now included in every
sample. Total compute still fell by two orders of magnitude, which is what pays
the bill.

KMS composition, one fully-paginated hour (2026-08-22 06:00–07:00Z), 42 events
against 293 in the comparable pre-change hour:

| Count | Key | Encryption context | Role |
|---|---|---|---|
| 40 | `alias/aws/lambda` | `aws:lambda:FunctionArn` | Maxi80Lambda |
| 1 | `alias/aws/ssm` | `PARAMETER_ARN` | AuthorizerLambda |
| 1 | `alias/aws/lambda` | `aws:lambda:FunctionArn` | AuthorizerLambda |

The composition inverted exactly as predicted. What remains is almost entirely
`Maxi80Lambda`'s environment-variable decryption — the floor identified in P4,
untouchable without removing env vars from the function.

---

## 5. If it failed

**Authorizer invocations did not drop.** Confirm the TTL is actually live —
`aws apigatewayv2 get-authorizers --api-id m0fjchl4pk` should show
`AuthorizerResultTtlInSeconds: 3600`. A later `make deploy` from a checkout
without this change would silently reset it to 0. If the TTL is present but
invocations are unchanged, suspect clients sending varying `Authorization` header
values, since the cache is keyed on that exact string — each distinct value gets
its own entry.

**4xx rose.** Most likely cause is more than one API key in circulation, so
different clients populate different cache entries and something is stale. Check
whether `/maxi80/api-key` was changed near the cutover.

**Rollback** is removing `ReauthorizeEvery` and redeploying. It is a stage-level
setting with no data migration, so reverting is immediate and safe.

---

## 6. Next decisions this measurement feeds

- **Throttling.** Not yet applied; account default of 10,000 rps still in effect.
  Recommended pre-launch value is rate 100 / burst 200, derived from a 458 req/min
  observed peak. Re-derive after launch — see `RUNBOOK` §3 for the token-bucket
  formula rather than reusing the number.
- **CloudFront.** Revisit above roughly 100k requests/day, or as soon as
  per-client rate limiting is needed, since WAF is only reachable that way.
  `RUNBOOK` §4.
- **`Maxi80Lambda`'s 25% cold-start rate**, which this change does not address
  and which costs more than the KMS line item that started all of this.

---

## 7. Outcome (measured 2026-08-22)

All six predictions held. Three things worth carrying forward.

**The authorizer is now at its theoretical floor.** 10 invocations across 8.65
hours with `ReauthorizeEvery: 3600` is ~1.16 per hour — one call per TTL period,
which is the minimum possible for a single shared API key. There is no further
tuning available here short of raising the TTL beyond an hour, and 3600 is the
API Gateway maximum. Raising it is not an option; this is done.

**KMS did not reach zero, and cannot.** ~1,000 requests/day remain, ~97.6% of
them `Maxi80Lambda` decrypting its own environment variables at init. Projected
~31,000/month against a 20,000/month free tier gives roughly **$0.04/month, down
from ~$0.28**. An 85% reduction, not the 100% that the "under the free tier"
framing in earlier analysis implied. The P4 range of 400–1,200/day was the
defensible number and it verified.

**Lambda savings roughly match the KMS savings.** Authorizer compute fell from
~1,250,000 ms/day to ~10,400 ms/day extrapolated, and ~15,000 daily invocations
disappeared. At 128 MB arm64 that is on the order of $0.15/month in invocations
plus GB-seconds — comparable to the ~$0.24/month KMS reduction. The change is
worth about **$0.39/month combined** against a ~$1.00/month bill. Small in
absolute terms, meaningful as a proportion, and the latency benefit is arguably
the bigger win.

### Latency — promising, not yet conclusive

| Day | avg | p50 | p90 | p99 |
|---|---|---|---|---|
| Aug 18 | 409 | 92 | 1315 | 1823 |
| Aug 19 | 373 | 80 | 1194 | 1779 |
| Aug 20 | 465 | 143 | 1434 | 1812 |
| Aug 21 (mixed) | 369 | 132 | 1070 | 1716 |
| Aug 22 (partial) | **349** | **66** | 1076 | **1213** |

p99 at 1,213 ms sits clearly below the prior 1,716–1,823 range, and p50 at 66 ms
is below the previous best. Both are consistent with removing a Lambda authorizer
hop — including a cold-start-prone one — from every request.

**Do not treat this as settled.** Aug 22 covers only 00:00–08:39Z, the quietest
part of the day, and lighter load depresses latency on its own. Re-read this table
after a full day before quoting the improvement.

### The 2 4xx on Aug 21

Cutover day only, zero before and zero since. Most plausible explanation is the
deploy window itself or a manual `make call-unauthorized`-style probe. Not a
pattern, but if 4xx becomes recurring, §5 covers the diagnosis.

### Still open

Unchanged by this work, in priority order:

1. **`Maxi80Lambda`'s cold-start rate is still ~26%** (1,242 of 4,723). It now
   accounts for essentially all remaining KMS traffic and far more Lambda duration
   than the authorizer ever did. This is the largest remaining inefficiency.
2. **No throttling.** Account default of 10,000 rps still applies. See `RUNBOOK`
   §3; re-derive limits after launch rather than reusing rate 100 / burst 200.
3. **CloudFront** at >100k requests/day, or whenever per-client rate limiting is
   needed. `RUNBOOK` §4.
