# Maxi80 Backend

The server-side Swift backend for **Maxi 80**, the French 80s radio station. It is a set of
AWS Lambda functions that (1) serve a small authenticated HTTP API to the mobile apps and
(2) collect now-playing metadata and album artwork from the live Icecast stream into S3.

The iOS / Android / Skip client lives in a separate repository — nothing here is client code.

> For a deeper architectural walkthrough see [`CLAUDE.md`](CLAUDE.md). For collector operations
> (local invoke, log filtering) see [`README-IcecastMetadataCollector.md`](README-IcecastMetadataCollector.md).

## What it does

- **Station information** — `GET /station` returns the station's name, stream URL, and descriptions.
- **Now-playing artwork** — `GET /artwork` returns a pre-signed S3 URL for a song's cover art.
- **Play history** — `GET /history` serves the recent play history collected from the stream.
- **Metadata collection** — a scheduled Lambda reads the Icecast stream every 3 minutes, enriches
  each track via the Apple Music API, and stores metadata, artwork, and a rolling `history.json` in S3.
- **Authentication** — every HTTP API request is checked by a Lambda authorizer that validates the
  `Authorization` header against an API key in AWS Systems Manager Parameter Store.

## Architecture

```
┌───────────┐   ┌──────────────┐   ┌────────────────┐   ┌──────────────┐
│ Mobile app│──▶│   HTTP API   │──▶│ AuthorizerLambda│──▶│ Maxi80Lambda │
│           │   │ (API GW v2)  │   │ (API key check) │   │  (routing)   │
└───────────┘   └──────────────┘   └───────┬────────┘   └──────┬───────┘
                                           │                    │
                                           ▼                    ▼
                                   ┌────────────────┐   ┌──────────────┐
                                   │ Parameter Store│   │  S3 (artwork │
                                   │  (/maxi80/*)   │   │  + history)  │
                                   └────────────────┘   └──────▲───────┘
                                                                │
  ┌─────────────────┐   ┌──────────────────────────┐           │
  │ Apple Music API │◀──│ IcecastMetadataCollector │───────────┘
  │                 │   │  (scheduled, every 3 min) │
  └─────────────────┘   └──────────────────────────┘
```

The project is one Swift Package with a shared library and several executables:

| Target | Kind | Role |
|--------|------|------|
| `Maxi80Backend` | library | Shared core: AWS adapters, Apple Music client, HTTP client, metadata parser, models. Depended on by everything else. |
| `Maxi80Lambda` | executable (Lambda) | The HTTP API behind API Gateway (HTTP API v2). Routes `/station`, `/artwork`, `/history`. |
| `AuthorizerLambda` | executable (Lambda) | API Gateway Lambda authorizer validating the `Authorization` header against `/maxi80/api-key`. |
| `IcecastMetadataCollector` | executable (Lambda) | Scheduled collector: reads the stream, enriches via Apple Music, writes to S3, maintains `history.json`. |
| `SotoS3`, `SotoSSM` | libraries | Minimal, code-generated AWS service clients (soto-codegenerator), each depending only on `SotoCore`. |
| `Maxi80CLI` | executable | Local dev CLI (`store-secrets`, `get-secrets`, `search`). |
| `ParseMetadata`, `CollectAppleMusic` | executables | One-off local scripts. Not deployed. |

### Routing (lambda-kit)

`Maxi80Lambda` uses the `Routing` library from a **fork** of SongShift/lambda-kit
(`sebsto/lambda-kit`, branch `support-runtime-3`) that widens the runtime pin to 3.x. `Maxi80Router.swift`
owns the route table; `Actions.swift` holds one `Action` struct per endpoint — `StationAction`,
`ArtworkAction`, `HistoryAction` — each constructor-injected with its dependencies. This replaced the
project's older custom router. `Package.resolved` pins the exact fork commit.

### AWS clients (Soto, not aws-sdk-swift)

AWS access goes through minimal, hand-generated Soto clients under `Sources/Soto/{S3,SSM}` (emitted by
soto-codegenerator; regenerate with `scripts/generate-soto-services.sh`). These replaced **aws-sdk-swift**,
whose aws-crt TLS layer crashed at Lambda cold start. Only `SotoCore` (pure Swift, AsyncHTTPClient
transport) is used at runtime. Lambda handlers go through the `S3Manager` / `ParameterStoreManager`
adapters in `Sources/Maxi80Backend/AWS/`, never raw Soto calls.

### Collector history invariant

A played track **always** lands in `history.json`, even when artwork enrichment fails: the collector
records history in exactly one place and degrades to a `nocover.jpg` entry on any thrown error. Only a
stream-read failure or empty metadata records nothing. See the collector section in
[`CLAUDE.md`](CLAUDE.md) for the full pipeline.

## API endpoints

All endpoints require an `Authorization` header carrying the API key, validated by the Lambda authorizer.

### `GET /station`

Returns the station information (`Station.default`):

```json
{
  "name": "Maxi 80",
  "streamUrl": "https://audio1.maxi80.com",
  "image": "maxi80_nocover-b.png",
  "shortDesc": "La radio de toute une génération",
  "longDesc": "Le meilleur de la musique des années 80",
  "websiteUrl": "https://maxi80.com",
  "donationUrl": "https://www.maxi80.com/paypal.htm",
  "defaultCoverUrl": "file://maxi80_nocover-b.png"
}
```

### `GET /artwork?artist={artist}&title={title}`

Checks S3 for `v2/<artist>/<title>/artwork.jpg`. Returns a pre-signed GET URL if present:

```json
{ "url": "https://<bucket>.s3.<region>.amazonaws.com/v2/<artist>/<title>/artwork.jpg?..." }
```

If no artwork exists, responds with `204 No Content`. Missing `artist` or `title` parameters return `400`.

### `GET /history`

Streams `v2/history.json` back verbatim. If no history has been collected yet, returns `{"entries":[]}`.

## Prerequisites

- **Swift 6.3+** toolchain (native build requires **macOS 26+**)
- **Docker** — used to cross-compile the Lambda binaries for Amazon Linux 2023
- **AWS CLI** configured with the `maxi80` profile
- **SAM CLI** for deployment
- **Apple Music API credentials** (Team ID, Key ID, Private Key)

## Build & test locally

```bash
swift build          # native macOS build (fast dev loop)
swift test           # full test suite (Swift Testing)
make test            # same as swift test
make format          # swift-format in place over Package.swift, Sources, Tests
```

Run a single test suite or test:

```bash
swift test --filter MetadataCollectorTests
swift test --filter HistoryManagerTests
```

`swift build` compiles natively for development and tests only. Deployable artifacts are
**cross-compiled for Amazon Linux 2023 in Docker** — never ship a native macOS binary.

## Configuration

Runtime configuration is passed to the functions as environment variables (defaults set in
`template.yaml`):

**Maxi80Lambda**
- `S3_BUCKET` — bucket holding collected artwork and history
- `KEY_PREFIX` — key prefix within the bucket (`v2`)
- `URL_EXPIRATION` — pre-signed URL lifetime in seconds (`3600`)

**AuthorizerLambda**
- `API_KEY_PARAMETER` — Parameter Store path of the API key (`/maxi80/api-key`)

**IcecastMetadataCollector**
- `STREAM_URL` — Icecast stream URL (`https://audio1.maxi80.com`)
- `S3_BUCKET`, `KEY_PREFIX` — S3 destination for metadata and history
- `SECRETS` — Parameter Store path of the Apple Music key (`/maxi80/apple-music-key`)
- `MAX_HISTORY_SIZE` — maximum number of history entries to keep (`100`)

`AWS_REGION` is also honored by the AWS adapters.

### Secrets in Parameter Store

Secrets live in SSM Parameter Store under `/maxi80/` as `SecureString` values:

- `/maxi80/api-key` — the API key the authorizer validates
- `/maxi80/apple-music-key` — the Apple Music private key / Team ID / Key ID (JSON)

Inspect them with `make get-parameters`.

To seed the Apple Music secret, create `Sources/Maxi80CLI/Secret.swift` (it is
gitignored — never commit real credentials) defining `Secret.appleMusicSecret`
(the private key / Team ID / Key ID) and `Secret.name`, then:

```bash
swift run Maxi80CLI --profile maxi80 --region eu-central-1 store-secrets
swift run Maxi80CLI --profile maxi80 --region eu-central-1 get-secrets    # verify
```

## Deploying

The deploy stack is `Maxi80Backend-2025` (SAM, `template.yaml`), region **eu-central-1**. All three
functions are ARM64, `provided.al2023`, `bootstrap` handler. `samconfig.toml` defines two config
environments: `dev` (local, uses the `maxi80` AWS profile) and `ci` (used by GitHub Actions, no local
profile — credentials come from the assumed OIDC role).

### Local deploy (`make`)

```bash
make build     # cross-compiles the three Lambda products for al2023 via the
               # swift-aws-lambda-runtime lambda-build plugin (Apple `container` backend)
make deploy    # sam deploy --config-env dev --express
```

`make build` writes zips under `.build/plugins/AWSLambdaBuilder/outputs/…`, which `template.yaml`
references as its `CodeUri`s.

### CI/CD (GitHub Actions + OIDC)

Every push to `main` (and manual `workflow_dispatch`) runs `.github/workflows/deploy.yml`, which:

1. Runs `swift test`.
2. Cross-compiles the three Lambda zips with the `lambda-build` plugin, using the **Docker** backend
   (`--cross-compile docker`) instead of Apple's `container` CLI, on an arm64 runner.
3. Assumes a short-lived AWS role via **GitHub OIDC** (no long-lived access keys in the repo).
4. Runs `sam deploy --config-env ci`.

**One-time bootstrap:** run the provisioning script with an administrator identity to create the OIDC
provider and the scoped deploy role, then publish the role ARN as a repo variable:

```bash
AWS_PROFILE=maxi80 GITHUB_REPO=sebsto/maxi80-backend-swift scripts/setup-github-oidc.sh
# then set the printed ARN as the AWS_DEPLOY_ROLE_ARN repo variable:
gh variable set AWS_DEPLOY_ROLE_ARN --repo sebsto/maxi80-backend-swift --body "<role-arn>"
```

The role's trust policy is pinned to this repo on `refs/heads/main`.

## Testing the deployed API

The `Makefile` resolves the live API URL and API key from CloudFormation / Parameter Store:

```bash
make call-station        # GET /station
make call-artwork        # GET /artwork?artist=Pink Floyd&title=The Wall
make call-history        # GET /history
make call-unauthorized   # same request with a wrong key (should be rejected)
make get-parameters      # list /maxi80/* parameters (decrypted)
make stream-metadata     # print the current ICY StreamTitle from the live stream
```

Tail function logs:

```bash
make logs-maxi80
make logs-collector
make logs-authorizer
```

## Monitoring

`template.yaml` provisions CloudWatch alarms wired to an SNS topic (`Maxi80-API-Alerts`):

- **Lambda errors** on `Maxi80Lambda`
- **Lambda high duration** (timeout warning)
- **HTTP API high request count**

## CLI usage

```bash
# Search Apple Music
swift run Maxi80CLI --profile maxi80 --region eu-central-1 search "Pink Floyd"

# Store / retrieve the Apple Music secret in Parameter Store
swift run Maxi80CLI --profile maxi80 --region eu-central-1 store-secrets
swift run Maxi80CLI --profile maxi80 --region eu-central-1 get-secrets
```

## Conventions

- **Swift 6.3, strict concurrency**, warnings-as-errors, and several upcoming-feature flags
  (`ExistentialAny`, `InternalImportsByDefault`, `MemberImportVisibility`,
  `NonisolatedNonsendingByDefault`). The code-generated Soto clients use relaxed settings — do not apply
  the strict flags to them.
- **Dependency injection via init parameters**, protocol-oriented seams for testability
  (`S3ManagerProtocol`, `HTTPClientProtocol`, `IcecastReading`, `ArtworkDownloading`, …). Tests inject
  fakes and never hit AWS.
- **Swift Testing** (`@Test`, `#expect`, `#require`, `@Suite`) — not XCTest. Property-based tests sit
  alongside example tests.
- **swift-log `Logger`** passed through the call chain (never `print` in library/handler code — it must
  surface in CloudWatch).
- **Dependencies** are edited directly in `Package.swift`; `Package.resolved` pins the lambda-kit fork
  commit. Regenerate Soto clients with `scripts/generate-soto-services.sh`; do not hand-edit them.
- Run `make format` before committing.

## Adding a new endpoint

1. Add an `Action` struct in `Sources/Maxi80Lambda/Actions.swift`.
2. Register its route in `Maxi80Router.swift`.
3. Wire its dependencies where the router is constructed in `Sources/Maxi80Lambda/Lambda.swift`.

## Reference docs

- [`CLAUDE.md`](CLAUDE.md) — full architecture, collector pipeline, S3 layout, and conventions.
- [`README-IcecastMetadataCollector.md`](README-IcecastMetadataCollector.md) — collector operations.
- `docs/` — design and plan documents.
