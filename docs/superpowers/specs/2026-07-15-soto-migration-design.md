# Migrate backend off aws-sdk-swift → soto-core + minimal generated clients

**Date:** 2026-07-15
**Motivation:** `aws-sdk-swift` (aws-crt-swift 0.63.1) intermittently `fatalError`s at Lambda
cold start — `SDKDefaultIO.swift:77 "Tls Context failed to create"` (see aws-sdk-swift#1984,
unresolved upstream). Confirmed via CloudWatch: the crash is at CRT TLS-context init on cold start;
warm invocations are healthy. Songs whose collection lands on a crashing cold start are silently
dropped (never cached, never in history). aws-crt is the root cause, so we remove it entirely.

**Reference pattern:** `/Users/sst/code/odvpn/backend` — soto-core 7.x + per-service minimal
generated clients under `Sources/Soto/<Service>/`, one `AWSClient()` created at Lambda boot and
managed by a `ServiceGroup` for graceful shutdown.

## Scope

Backend only (`maxi-80-backend-swift`). The iOS/Android app is unaffected. The AWS surface is tiny
and already fully abstracted behind two protocols, so the blast radius is contained.

**AWS usage today (complete inventory):**
- **S3** (`S3Manager` behind `S3ManagerProtocol`): HeadObject, GetObject, PutObject, CopyObject,
  DeleteObject, GetBucketLocation, **presigned GET URL**.
- **SSM** (`ParameterStoreManager` behind `ParameterStoreProtocol`): GetParameter (withDecryption),
  PutParameter (SecureString). PutParameter is used only by the CLI secret tool.
- Region type (`Region.swift`) — custom string wrapper, already SDK-agnostic in its public surface.

**Presigned URLs are viable on soto-core**: `AWSClient.signURL(url:httpMethod:expires:serviceConfig:)`
exists (verified in soto-core main). This is the one non-obvious dependency and it's covered.

## Approach

Mirror odvpn exactly:
1. **Dependency swap** in `Package.swift`: remove `aws-sdk-swift` (AWSS3, AWSSSM, AWSSDKIdentity,
   Smithy). Add `soto-core` (`from: "7.13.0"`). Keep swift-aws-lambda-runtime, async-http-client.
2. **Generated minimal clients** under `Sources/Soto/S3/` and `Sources/Soto/SSM/` (each:
   `<Svc>_api.swift` + `<Svc>_shapes.swift`), produced by `soto-codegenerator` with an operation
   whitelist. Add `scripts/generate-soto-services.sh` (like odvpn) so it's reproducible. New SwiftPM
   targets `SotoS3`, `SotoSSM` depending on `SotoCore`.
   - S3 ops: `headObject, getObject, putObject, copyObject, deleteObject, getBucketLocation`
   - SSM ops: `getParameter, putParameter`
3. **Rewrite the two wrapper files** to use soto instead of aws-sdk-swift, keeping their protocols
   **byte-for-byte identical** so all call sites (Actions, S3Writer, HistoryManager, CLI) are
   untouched:
   - `S3Manager.swift`: `S3Client` → `S3` (soto). Map error checks `AWSS3.NotFound`/`NoSuchKey`
     → soto `S3ErrorType`/HTTP 404. `presignedGetURL` → `client.signURL(url:.GET,expires:,serviceConfig:s3.config)`.
     `resolveBucketRegion` → soto S3 `getBucketLocation` from a us-east-1 client.
   - `ParameterStoreManager.swift`: `SSMClient` → `SSM` (soto). `getParameter(withDecryption:true)`,
     `putParameter(type:.secureString)`. Drop `ProfileAWSCredentialIdentityResolver`; for CLI local
     profile use soto's credential-provider config (or `AWS_PROFILE` env, which soto honors).
4. **AWSClient lifecycle**: create one `AWSClient()` at each Lambda's boot; construct `S3`/`SSM` with
   it; wrap `AWSClient` + `LambdaRuntime` in a `ServiceGroup` (sigterm graceful) as odvpn does. The
   wrappers take an injected soto `S3`/`SSM` (constructor injection, same as today's `S3Client`).
   This also removes the per-call `S3ClientConfig` creation that currently re-inits CRT.

## Module wiring

- `Maxi80Backend` target: depends on `SotoS3`, `SotoSSM` (was AWSS3, AWSSSM).
- `Maxi80Lambda`, `IcecastMetadataCollector`: depend on `SotoS3` (+ SotoCore for `AWSClient`/`Region`).
- Region: keep the existing custom `Region` type for the app-facing API, but map to
  `SotoCore.Region` at the soto boundary (soto uses its own `Region`). Add a small
  `Region → SotoCore.Region` bridge (rawValue passthrough).
- `AuthorizerLambda`, other CLI/utility targets: unchanged (no AWS SDK today).

## Testing

- `MockS3Client` / mock SSM already implement the protocols → **unit tests need no changes** and are
  the regression guard that the wrapper rewrite preserved behavior.
- `swift build` + `swift test` (127 tests) green.
- Deploy the collector; verify in CloudWatch: **zero `Tls Context` fatals across cold starts**, and
  invocations log past "Parsed" (Cache hit / Selected song / Successfully collected).
- Verify `/artwork` still returns a working presigned URL (curl the endpoint, fetch the URL → 200).

## Risks & mitigations

- **Presigned URL correctness** — soto's `signURL` differs from aws-sdk's `presignURL`; verify the
  returned URL actually GETs the object (curl test) before considering done. HIGHEST risk.
- **S3 `getBucketLocation` quirk** — us-east-1 buckets return empty constraint; soto may model this
  differently. Preserve the "empty → us-east-1" fallback.
- **Bucket is in eu-west-1** (per logs) while Lambda is eu-central-1 — the region-resolution path is
  load-bearing; keep it.
- **Codegen availability** — if `soto-codegenerator` can't be run in this environment, fall back to
  copying the exact generated files from odvpn's `Sources/Soto/S3` + `Sources/Soto/SSM` (same
  soto-core version) and trimming to our operations. Either way the committed output is what matters.
- **CLI credential profile** — `ProfileAWSCredentialIdentityResolver` has no soto equivalent by that
  name; soto uses `AWSClient(credentialProvider:)` / `AWS_PROFILE`. CLI secret tool is dev-only.

## Parallelizable work (subagents)

Independent once the Package.swift + targets skeleton exists:
- **A. Generated S3 client** (`Sources/Soto/S3/*`) + `S3Manager.swift` rewrite + presign verify.
- **B. Generated SSM client** (`Sources/Soto/SSM/*`) + `ParameterStoreManager.swift` rewrite.
- **C. Lambda entry points** (`AWSClient`/`ServiceGroup` lifecycle in the 2 Lambda mains + Region
  bridge).
These touch disjoint files; a final serial integration pass wires targets and runs build+tests.

## Out of scope
- No behavior/feature changes. No app changes. No new AWS services.
- Not touching the DIAG breadcrumbs yet — they stay until we confirm zero cold-start fatals, then a
  cleanup commit removes them.
