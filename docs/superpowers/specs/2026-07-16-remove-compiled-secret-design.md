# Remove compiled-in secret; unblock CI

**Date:** 2026-07-16
**Status:** Approved

## Problem

CI (`.github/workflows/deploy.yml`) fails at the `swift test` step:

```
Sources/Maxi80CLI/CLIManageSecret.swift:19:65: error: cannot find 'Secret' in scope
```

`swift test` compiles the entire package graph, including the `Maxi80CLI` executable
target. `Maxi80CLI` references a `Secret` type defined only in
`Sources/Maxi80CLI/Secret.swift`, which is listed in `.gitignore` and therefore absent on
the CI checkout. The build cannot resolve `Secret`, so it fails.

`Secret.swift` also hardcodes a live Apple Music private key as a Swift constant
(`Secret.appleMusicSecret`) — a secret-in-source smell independent of the CI failure.

## Root cause

A source file that is **required to compile** was made **uncommittable** (to keep the key
out of git). The two requirements are incompatible. The fix is to make the file free of
any real secret so it can be committed.

## Current usage of `Secret`

- `Secret.name` — the constant string `/maxi80/apple-music-key`. Safe to commit.
- `Secret.appleMusicSecret` — the hardcoded key. **Only** consumer is the `StoreSecrets`
  (`store-secrets`) subcommand.
- `GetSecrets` and `Search` reference only `Secret.name`; they already fetch the secret
  from SSM at runtime via `ParameterStoreManager.getSecret`.

The secret is already bootstrapped in SSM: `/maxi80/apple-music-key`, `SecureString`,
version 1 (verified with `aws ssm get-parameter --profile maxi80`). Its decrypted JSON
matches the `AppleMusicSecret` shape (`privateKey`, `keyId`, `teamId`).

## Design

### 1. `Secret.swift` becomes committable

Reduce to the parameter name only; remove `appleMusicSecret` and the commented JSON block:

```swift
struct Secret {
    static let name = "/maxi80/apple-music-key"
}
```

Remove the `Secret.swift` entry from `.gitignore`. Commit the file. No live credential
remains in source.

### 2. `store-secrets` reads the key at runtime via `--key-file`

`StoreSecrets` gains a `--key-file <path>` option. It reads a JSON file, decodes it
directly into `AppleMusicSecret` (already `Codable`), and stores it to SSM under
`Secret.name`. The JSON shape matches the block previously commented at the bottom of
`Secret.swift`:

```json
{
  "keyId": "…",
  "privateKey": "-----BEGIN PRIVATE KEY-----\n…\n-----END PRIVATE KEY-----",
  "teamId": "…"
}
```

Usage:

```
Maxi80CLI store-secrets --key-file ./apple-music-key.json --profile maxi80
```

Rotation path preserved; no secret in source.

### 3. `GetSecrets` / `Search` unchanged

They already fetch from SSM via `Secret.name`, which survives.

### 4. CI unchanged

CI only compiles the CLI (`swift test`) and cross-compiles the three Lambdas; it never
runs the CLI. Once `Secret.swift` is committed, the build resolves `Secret` and passes.
No SSM access is required from GitHub — the runtime SSM fetch uses a local AWS profile
(`--profile`, already wired in `GlobalOptions.withAWSClient`).

## Data flow (runtime, unchanged)

SSM `/maxi80/apple-music-key` → `ParameterStoreManager.getSecret` → `AppleMusicSecret` →
`JWTTokenFactory`. The only new path is `store-secrets` reading a local JSON file instead
of a compiled-in constant.

## Testing

Add a Swift Testing case decoding a sample key-file JSON into `AppleMusicSecret` (and back)
so the `--key-file` contract is covered without hitting AWS. No test asserts against a real
key value.

## Out of scope

- Rotating the existing SSM value (already present; unchanged).
- Any client-app change — this backend change has no API/contract impact on the client.
