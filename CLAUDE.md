# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

This is the **backend** for Maxi80, the French 80s radio station "Maxi 80". It is a set of
server-side Swift AWS Lambda functions that (1) serve a small authenticated HTTP API to the mobile
apps and (2) collect now-playing metadata + artwork from the live Icecast stream into S3. The iOS /
Android / Skip client lives in a separate repository — nothing here is client code.

## Build & Test

```bash
swift build                       # Native macOS build (fast dev loop; requires macOS 26+)
swift test                        # Full test suite (Swift Testing)
make test                         # same as swift test
make format                       # swift-format in place over Package.swift, Sources, Tests
```

Run a single test suite or test:

```bash
swift test --filter MetadataCollectorTests
swift test --filter HistoryManagerTests
swift test --filter S3WriterTests
```

`swift build` compiles natively for local development and tests. Deployable Lambda artifacts are
**cross-compiled for Amazon Linux** in Docker — do not ship a native macOS binary:

```bash
make build     # cross-compiles IcecastMetadataCollector, Maxi80Lambda, AuthorizerLambda for al2023
make deploy     # sam deploy --config-env dev
```

`make build` uses the swift-aws-lambda-runtime plugin (`swift:amazonlinux2023` base) with Apple's container CLI
and writes zips under `.build/plugins/AWSLambdaBuilder/outputs/…` that `template.yaml` references.

### Swift settings (strict)

`Package.swift` compiles the first-party targets with **warnings-as-errors** plus the upcoming
features `ExistentialAny`, `InternalImportsByDefault`, `MemberImportVisibility`, and
`NonisolatedNonsendingByDefault`. Consequences to keep in mind when editing:

- `any` is required on every existential (`any S3ManagerProtocol`, `any Error`).
- Imports default to `internal`; use `public import` when a type from a dependency appears in this
  module's public API (see `Maxi80Router.swift` / `S3Manager.swift`).
- A new warning fails the build. The code-generated Soto clients under `Sources/Soto/` are exempted
  via a relaxed `sotoSwiftSettings` because the generator doesn't satisfy these flags — do not apply
  the strict settings to them.

## Deployment target & AWS

- Stack: `Maxi80Backend-2025` (SAM, `template.yaml`), region **eu-central-1**, AWS profile
  **maxi80**. All three functions are ARM64, `provided.al2023`, `bootstrap` handler.
- Secrets/config live in **SSM Parameter Store** under `/maxi80/` (SecureString): `api-key`,
  `apple-music-key`. Inspect with `make get-parameters`.
- Artwork/metadata/history are stored in the S3 bucket `artwork.maxi80.com` under the `v2/` prefix
  (`KEY_PREFIX`). The bucket name contains dots, which forces **path-style** S3 URLs (see the note in
  `S3Manager.presignedGetURL` — virtual-hosted style breaks TLS cert matching).
- Logs / manual invoke helpers: `make logs-collector`, `make logs-maxi80`, `make logs-authorizer`,
  `make call-station|call-artwork|call-history|call-unauthorized`, `make stream-metadata`.

## Architecture

Swift Package with one shared library and several executables. Products in `Package.swift`:

| Target | Kind | Role |
|--------|------|------|
| `Maxi80Backend` | library | Shared core: AWS adapters, Apple Music client, HTTP client, metadata parser, models. Depended on by everything else. |
| `Maxi80Lambda` | executable (Lambda) | The **HTTP API** behind API Gateway (HTTP API v2). Routes `/station`, `/artwork`, `/history`. |
| `AuthorizerLambda` | executable (Lambda) | API Gateway Lambda **authorizer**: validates the `Authorization` header against `/maxi80/api-key`. |
| `IcecastMetadataCollector` | executable (Lambda) | Scheduled **collector**: reads the Icecast stream every 3 min, enriches via Apple Music, writes to S3, maintains `history.json`. |
| `SotoS3`, `SotoSSM` | libraries | Minimal **code-generated** AWS clients (soto-codegenerator), each depending only on `SotoCore`. |
| `Maxi80CLI` | executable | Local dev CLI (`store-secrets`, `get-secrets`, `search` Apple Music). |
| `ParseMetadata`, `CollectAppleMusic` | executables | One-off local scripts (batch parse metadata files / collect Apple Music results). Not deployed. |

### Why hand-generated Soto clients instead of aws-sdk-swift

`Sources/Soto/{S3,SSM}` are minimal service clients emitted by soto-codegenerator (regenerate with
`scripts/generate-soto-services.sh`). They replaced **aws-sdk-swift**, whose aws-crt TLS layer
crashed at Lambda cold start (`SDKDefaultIO.swift:77`). Only `SotoCore` (pure-Swift, AsyncHTTPClient
transport) is used at runtime. Keep AWS access going through the `S3Manager` / `ParameterStoreManager`
adapters in `Maxi80Backend/AWS/`, not raw Soto calls in Lambda handlers.

### lambda-kit routing

`Maxi80Lambda` uses the `Routing` library from a **fork** of SongShift/lambda-kit
(`sebsto/lambda-kit`, branch `support-runtime-3`) that widens the runtime pin to 3.x. `Package.resolved`
pins the exact commit. `Maxi80Router` owns the route table; `Actions.swift` holds one `Action` struct
per endpoint (`StationAction`, `ArtworkAction`, `HistoryAction`), each constructor-injected with its
dependencies.

### HTTP API endpoints (`Maxi80Lambda`)

- `GET /station` — returns the hardcoded `Station.default` (station name, stream URL, descriptions).
- `GET /artwork?artist=&title=` — HEADs `v2/<artist>/<title>/artwork.jpg`; returns a **pre-signed
  GET URL** if present, else `204 No Content`.
- `GET /history` — streams `v2/history.json` back verbatim; `{"entries":[]}` if absent.

All three are behind the Lambda authorizer; missing query params throw `QueryParameterError` → 400.

### Collector pipeline (`IcecastMetadataCollector`)

`Lambda.swift` builds the dependencies (shared `AWSClient`, resolved bucket region, Apple Music JWT
from Parameter Store) and injects them into `MetadataCollector`, whose `collect(logger:)` runs one
cycle. Business logic is fully extracted from the handler so it is unit-testable with fakes
(`Tests/…/Mocks/`, `CollectorFakes.swift`). One cycle:

1. `IcecastReader` reads the raw ICY `StreamTitle`.
2. `parseTrackMetadata` (in `Maxi80Backend/MetadataParser.swift`) splits `artist - title`.
3. Dedup vs. the latest `history.json` entry; skip if unchanged.
4. `"Maxi80"` / `"Maxi 80"` filler artist → record a `nocover.jpg` history entry, skip Apple Music.
5. S3 cache check (`metadata.json`); on hit, reuse (backfilling dominant color if missing).
6. Legacy stripped-title → full-title cache **migration** (see title/parenthesis rule below).
7. Fresh Apple Music **search** (`SongSelector` picks the best match) → download artwork → write
   `metadata.json` / `search.json` / `artwork.jpg` to S3.

**History invariant (important):** a played track must ALWAYS land in `history.json`, even with no
cover or when enrichment fails. `collect` records history in **exactly one place** and wraps the
enrichment in a `do/catch` that degrades to a `nocover.jpg` entry on any thrown error. Only a
stream-read failure or empty metadata records nothing. Do not reintroduce per-branch `recordHistory`
calls that could be bypassed by an upstream throw. `S3Manager.getObject` returns `nil` (not throw) for
a missing object so a cache miss never aborts the cycle.

**Title / parenthesis rule:** the **stored and displayed** title keeps trailing parentheses
(`Don't go (maxi)`, `PYT (Pretty Young Thing)`); only the **Apple Music search term** drops the
trailing `(...)` group via `searchTitle(_:)`, because remix/edit annotations hurt match quality.
Legacy objects were stored under the stripped title, hence the migration step.

### S3 layout

```
v2/
├── history.json                      ← rolling history (default cap 100), served by GET /history
├── <Artist>/<Title>/
│   ├── metadata.json                 ← raw ICY metadata + timestamp + dominant color
│   ├── search.json                   ← Apple Music search response
│   └── artwork.jpg                   ← album artwork (absent for coverless tracks → "nocover.jpg")
```

## Conventions

- **Swift 6.3, strict concurrency.** Structured concurrency (`async/await`, `async let`) over GCD.
  Types are `Sendable`; shared AWS clients are value/actor types reused across warm invocations.
- **Dependency injection via init parameters**, protocol-oriented seams for testability:
  `S3ManagerProtocol`, `HTTPClientProtocol`, `AuthorizationProvider`, `IcecastReading`,
  `ArtworkDownloading`. Tests inject fakes/mocks (`Tests/Maxi80BackendTests/Mocks/`), never hit AWS.
- **Testing:** Swift Testing (`@Test`, `#expect`, `#require`, `@Suite`) — not XCTest. Property-based
  tests exist alongside example tests (e.g. `*PropertyTests.swift`, S3 key construction, Icecast
  round-trip). Prefer adding a fake over reaching for a mocking framework.
- **Logging:** swift-log `Logger` passed through the call chain (never `print` in library/handler
  code — it must surface in CloudWatch). Use `.debug` for path breadcrumbs, `.info` for lifecycle,
  `.warning`/`.error` for degraded/failed paths. The collector emits `"Path: …"` breadcrumbs on every
  branch so a missing-track incident is diagnosable from logs alone.
- **AWS access** goes through the adapters in `Maxi80Backend/AWS/`, using the shared `AWSClient`.
  Environment overrides: `AWS_REGION`, `S3_BUCKET`, `KEY_PREFIX`, `MAX_HISTORY_SIZE`, `STREAM_URL`,
  `URL_EXPIRATION`, `API_KEY_PARAMETER`, `SECRETS`.
- **Dependencies** are edited directly in `Package.swift`; `Package.resolved` pins the lambda-kit
  fork commit. Regenerate Soto clients with `scripts/generate-soto-services.sh`, don't hand-edit them.
- Run `make format` before committing.

## Reference docs

- `README-IcecastMetadataCollector.md` — collector operations: local invoke, deploy, log filtering.
- `docs/` — design/plan docs (e.g. `SPEC-dominant-color.md`, `PLAN-history-missing-on-cache-miss.md`).
