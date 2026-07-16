# Migrate Maxi80Lambda routing to lambda-kit `Routing`

**Date:** 2026-07-16
**Status:** Approved

## Goal

Replace the hand-rolled routing layer in `Maxi80Lambda` with the `Routing`
library from [lambda-kit](https://github.com/SongShift/lambda-kit). Only
`Maxi80Lambda` is affected — `AuthorizerLambda` (a Lambda authorizer) and
`IcecastMetadataCollector` (an EventBridge-scheduled function) have no HTTP
routing and are out of scope.

## Why

The custom stack (`Router` + `RouterError`, the `Action` protocol's routing
properties, and `Maxi80Endpoint`/`PathMatchable`) reimplements
method+path dispatch, method-not-allowed handling, and parameter validation
that `Routing` provides as a typed, tested library. Adopting it removes code we
maintain and gives us a trie router with automatic 404/400/500 handling.

## Approach (chosen: A — thin router, keep action structs)

Keep the three action structs as dependency-holding units (they carry the S3
client, bucket, key prefix, expiration), but drop the `Action` protocol and its
`endpoint`/`method` routing metadata. Register their handlers on a lambda-kit
`HTTPRouter` built once at cold start.

Handlers are reworked to the lambda-kit-native signature
`(HTTPRequest, Logger) async throws -> RouteResponse` (option B), so query
parameters go through `HTTPRequest.queryParameters` and results are expressed
as `RouteResponse` instead of raw `Data`.

## Infrastructure

No change. API Gateway already routes `/{proxy+}` with method `ANY`
(`template.yaml`), which is exactly what lambda-kit's `HTTPRequest` expects —
it derives the routing path from `event.pathParameters["proxy"]`.

## Package changes

- Add dependency `.package(url: "https://github.com/SongShift/lambda-kit.git", branch: "main")`.
  lambda-kit has no tagged release; `Package.resolved` pins the resolved commit
  for reproducible builds.
- `Maxi80Lambda` target gains `.product(name: "Routing", package: "lambda-kit")`.

## File-level changes

### Deleted
- `Sources/Maxi80Lambda/Router.swift` — custom `Router` + `RouterError`.
- `Sources/Maxi80Backend/Endpoint.swift` — `Maxi80Endpoint` + `PathMatchable`
  (used only by the routing layer).

### `Sources/Maxi80Lambda/Actions.swift`
- Remove the `Action` protocol and the `endpoint`/`method` properties.
- Remove `ActionError` (replaced by lambda-kit's typed `QueryParameterError`,
  which auto-maps to 400).
- Keep `ArtworkResponse`.
- Each struct keeps its dependencies and exposes
  `handle(_ request: HTTPRequest, _ logger: Logger) async throws -> RouteResponse`:
  - **StationAction** → `.json(Station.default)`.
  - **ArtworkAction** → `try request.queryParameters.require("artist")` and
    `require("title")` (throwing → auto-400). S3 miss →
    `.empty(statusCode: .ok)`; hit → `.json(ArtworkResponse(url:))`.
  - **HistoryAction** → returns the raw `history.json` as `.string(...)`, or
    `.json(["entries": [String]()])` when the object is absent.

### `Sources/Maxi80Lambda/Lambda.swift`
- Build `HTTPRouterBuilder` at cold start, registering `get("/station")`,
  `get("/artwork")`, `get("/history")` closures that call the captured actions.
- `handle(_:context:)` collapses to:
  ```swift
  let response = await router.handle(HTTPRequest(event: event), logger: context.logger)
  return APIGatewayV2Response(statusCode: response.statusCode,
                              headers: response.headers,
                              body: response.body)
  ```
- Remove the manual `do/catch` for `RouterError`/`ActionError`/500 — lambda-kit
  handles unmatched routes (404), typed param errors (400), and unhandled
  throws (500).

## Behavior deltas

| Case | Before | After |
|------|--------|-------|
| Unknown path | 404 | 404 (unchanged) |
| Known path, wrong method (e.g. `POST /station`) | 405 | **404** (accepted) |
| Missing `artist`/`title` | 400 | 400 (auto, via `QueryParameterError`) |
| Artwork not found | 200 empty body | 200 empty body (unchanged) |
| Unhandled S3 error | 500 | 500 (unchanged) |

## Tests

- **Delete** `RouterTests` and `RouterPropertyTests` — they target the removed
  `Router`/`Maxi80Endpoint`.
- **Rewrite** action-level tests (station/artwork/history) to call the new
  `HTTPRequest`-based handlers directly with `MockS3Client`, asserting on
  `RouteResponse` status and body.
- **Add** router-level tests that drive the built `HTTPRouter` end-to-end via
  `router.handle(HTTPRequest(event:), logger:)`: 200 on `/station`, 400 on
  missing `artist`, 404 on unknown path, 404 on `POST /station`.
- `LambdaHandlerTests` initialization test stays (still constructs
  `Maxi80Lambda(s3Client:)`).

## Verification

- `swift build` under strict concurrency (warnings-as-errors).
- Run the full test suite.
- Drive the built router with sample `APIGatewayV2Request` fixtures for each
  endpoint plus the 400 and 404 cases, observing the returned status/body.
