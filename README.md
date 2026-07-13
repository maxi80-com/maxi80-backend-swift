# Maxi80 Backend

A Swift-based serverless backend for the Maxi80 radio station iOS app, providing station information, now-playing artwork, and play history through AWS Lambda and an HTTP API Gateway.

## Overview

Maxi80 Backend is a modern Swift serverless application that provides:

- **Station Information**: Returns Maxi80 radio station details and streaming information
- **Now-Playing Artwork**: Returns pre-signed S3 URLs for the cover art of the currently playing song
- **Play History**: Serves the recent play history collected from the Icecast stream
- **Metadata Collection**: A scheduled Lambda reads the Icecast stream, fetches artwork from Apple Music, and stores metadata and history in S3
- **Secure Authentication**: HTTP API requests are authorized by a Lambda authorizer validating an API key stored in AWS Systems Manager Parameter Store
- **CLI Tools**: Command-line interface for testing and secret management

## Architecture

```
┌─────────────┐   ┌──────────────┐   ┌────────────────┐   ┌──────────────┐
│   iOS App   │──▶│   HTTP API   │──▶│ Lambda         │──▶│  Maxi80Lambda│
│             │   │  (API GW v2) │   │ Authorizer     │   │  (Swift)     │
└─────────────┘   └──────────────┘   └────────────────┘   └──────┬───────┘
                                             │                    │
                                             ▼                    ▼
                                     ┌────────────────┐   ┌──────────────┐
                                     │ Parameter Store│   │  S3 (artwork │
                                     │ (/maxi80/*)    │   │  + history)  │
                                     └────────────────┘   └──────▲───────┘
                                                                  │
   ┌─────────────────┐   ┌───────────────────────┐               │
   │ Apple Music API │◀──│ IcecastMetadataCollector│─────────────┘
   │                 │   │ (scheduled, every 3 min)│
   └─────────────────┘   └───────────────────────┘
```

## Project Structure

```
Sources/
├── Maxi80Lambda/           # AWS Lambda handler (HTTP API backend)
│   ├── Lambda.swift        # Main Lambda function
│   ├── Router.swift        # Request routing
│   └── Actions.swift       # Endpoint action handlers (station, artwork, history)
├── AuthorizerLambda/       # Lambda authorizer validating the API key
│   └── Lambda.swift
├── Maxi80Backend/          # Core backend library
│   ├── AppleMusic/         # Apple Music API integration
│   │   ├── AppleMusic.swift
│   │   ├── AppleMusicAuthProvider.swift
│   │   ├── AppleMusicAuthentication.swift
│   │   └── AppleMusicModel.swift
│   ├── AWS/                # AWS service integrations
│   │   ├── Region.swift
│   │   ├── S3Manager.swift
│   │   └── ParameterStoreManager.swift
│   ├── HTTPClient/         # HTTP client utilities
│   │   ├── HTTPClient.swift
│   │   └── HTTPLogger.swift
│   ├── Endpoint.swift      # API endpoint definitions
│   ├── Maxi80APIClient.swift
│   ├── MetadataParser.swift
│   └── Station.swift       # Station data model
├── IcecastMetadataCollector/ # Scheduled Icecast stream metadata collector Lambda
│   ├── Lambda.swift
│   ├── IcecastReader.swift
│   ├── ArtworkDownloader.swift
│   ├── CollectedMetadata.swift
│   ├── Errors.swift
│   ├── HistoryManager.swift
│   ├── S3Writer.swift
│   └── SongSelector.swift
└── Maxi80CLI/              # Command-line interface
    ├── CLIMain.swift       # CLI entry point
    ├── CLISearch.swift     # Search command
    ├── CLIManageSecret.swift # Secret management
    ├── Region+ExpressibleByArgument.swift
    └── GlobalOptions.swift # Shared CLI options
```

## API Endpoints

All endpoints require an `Authorization` header carrying the API key, which is
validated by the Lambda authorizer.

### GET /station
Returns Maxi80 radio station information.

**Response:**
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

### GET /artwork?artist={artist}&title={title}
Returns a pre-signed S3 URL for the cover art of the given song, if it has been
collected.

**Parameters:**
- `artist` (required): Artist name
- `title` (required): Song title

**Response:**
Returns a JSON object with a pre-signed URL when the artwork exists:
```json
{
  "url": "https://<bucket>.s3.<region>.amazonaws.com/v2/<artist>/<title>/artwork.jpg?..."
}
```
When no artwork is found, the endpoint responds with `204 No Content` and an
empty body.

### GET /history
Returns the recent play history collected from the Icecast stream.

**Response:**
```json
{
  "entries": [
    {
      "artist": "Pink Floyd",
      "title": "Another Brick in the Wall",
      "artwork": "v2/Pink Floyd/Another Brick in the Wall/artwork.jpg",
      "timestamp": "2025-01-15T14:30:00Z"
    }
  ]
}
```
If no history has been collected yet, an empty `{"entries":[]}` object is
returned.

## Prerequisites

- **Swift 6.2+**
- **Docker** (for Lambda packaging)
- **AWS CLI** configured with appropriate credentials
- **SAM CLI** for deployment
- **Apple Music API credentials** (Team ID, Key ID, Private Key)

## Setup

### 1. Clone and Install Dependencies

```bash
git clone <repository-url>
cd maxi-80-backend-swift
swift package resolve
```

### 2. Configure AWS Credentials

Set up your AWS profile for the target account:

```bash
aws configure --profile maxi80
# Enter your AWS Access Key ID, Secret Access Key, and region (eu-central-1)
```

### 3. Store Apple Music Credentials

Create a `Sources/Maxi80CLI/Secret.swift` file (not tracked in git):

```swift
import Maxi80Backend

enum Secret {
    static let name = "/maxi80/apple-music-key"
    static let appleMusicSecret = AppleMusicSecret(
        privateKey: "-----BEGIN PRIVATE KEY-----\n...\n-----END PRIVATE KEY-----",
        teamId: "YOUR_TEAM_ID",
        keyId: "YOUR_KEY_ID"
    )
}
```

Store the secret in AWS Systems Manager Parameter Store:

```bash
swift run Maxi80CLI --profile maxi80 --region eu-central-1 store-secrets
```

You also need to store the API key used by the Lambda authorizer at
`/maxi80/api-key` (a `SecureString` parameter).

## Building and Deployment

### Build the Lambda Functions

```bash
make build
```

This command:
- Compiles both Lambda functions (Maxi80Lambda and IcecastMetadataCollector) in a single Docker invocation
- Strips debug symbols from the binaries to reduce size (~190 MB → ~85 MB)
- Copies the bootstraps and template into `.aws-sam/build/`

### Deploy to AWS

```bash
make deploy
```

This deploys the entire stack including:
- Maxi80Lambda function (HTTP API backend)
- AuthorizerLambda function (API key Lambda authorizer)
- IcecastMetadataCollector function (scheduled stream metadata collector)
- HTTP API Gateway with a Lambda authorizer
- IAM roles and policies
- CloudWatch alarms and SNS topic for monitoring

### Format Code

```bash
make format
```

## Testing the API

### Test Station Endpoint

```bash
make call-station
```

### Test Artwork Endpoint

```bash
make call-artwork
```

### Test History Endpoint

```bash
make call-history
```

### Test an Unauthorized Request

```bash
make call-unauthorized
```

### List Parameters (including the API key)

```bash
make get-parameters
```

## CLI Usage

The project includes a command-line interface for testing and management:

### Search Apple Music

```bash
swift run Maxi80CLI --profile maxi80 --region eu-central-1 search "Pink Floyd"
```

### Manage Secrets

```bash
# Store secrets
swift run Maxi80CLI --profile maxi80 --region eu-central-1 store-secrets

# Retrieve secrets
swift run Maxi80CLI --profile maxi80 --region eu-central-1 get-secrets
```

## Configuration

### Environment Variables

The backend functions use these environment variables:

**Maxi80Lambda** (HTTP API backend):
- `S3_BUCKET`: Bucket holding collected artwork and history (default: `artwork.maxi80.com`)
- `KEY_PREFIX`: Key prefix within the bucket (default: `v2`)
- `URL_EXPIRATION`: Pre-signed URL lifetime in seconds (default: `3600`)
- `AWS_REGION`: AWS region for services

**AuthorizerLambda**:
- `API_KEY_PARAMETER`: Parameter Store path of the API key (default: `/maxi80/api-key`)

**IcecastMetadataCollector**:
- `STREAM_URL`: Icecast stream URL
- `S3_BUCKET`, `KEY_PREFIX`: S3 destination for metadata and history
- `SECRETS`: Parameter Store path of the Apple Music key (default: `/maxi80/apple-music-key`)
- `MAX_HISTORY_SIZE`: Maximum number of history entries to keep

### SAM Configuration

The deployment configuration is in `samconfig.toml`:

```toml
[dev.deploy.parameters]
stack_name = "Maxi80Backend-2025"
region = "eu-central-1"
profile = "maxi80"
capabilities = "CAPABILITY_IAM"
```

## Security Features

- **Lambda Authorizer**: All HTTP API endpoints require a valid API key, validated by a dedicated Lambda authorizer
- **JWT Token Management**: Automatic Apple Music JWT token generation and caching
- **Secrets Management**: Apple Music credentials and the API key stored as `SecureString` parameters in AWS Systems Manager Parameter Store
- **IAM Least Privilege**: Each Lambda function has minimal required permissions

## Monitoring and Alerts

The stack includes CloudWatch alarms for:

- **Lambda Errors**: Function execution failures
- **Lambda Duration**: High execution times (timeout warning)
- **High Request Count**: HTTP API request count exceeding the configured threshold

Alerts are sent to an SNS topic for notification setup.

## Development

### Adding New Endpoints

1. Add the endpoint path to the `Maxi80Endpoint` enum in `Endpoint.swift`
2. Implement an `Action` conforming type in `Actions.swift`
3. Register the action in the `actions` array in `Maxi80Lambda/Lambda.swift`; the `Router` dispatches to it automatically

### Testing Locally

Use the CLI for local testing:

```bash
swift run Maxi80CLI search "test query"
```

### Code Style

The project uses `swift format` for consistent code formatting:

```bash
make format
```

## Dependencies

- **AWS Lambda Runtime**: Swift runtime for AWS Lambda
- **AWS Lambda Events**: Event types for API Gateway integration
- **JWT Kit**: JWT token generation for Apple Music API
- **AWS SDK Swift**: AWS service integrations (Systems Manager Parameter Store, S3)
- **Async HTTP Client**: HTTP client for Apple Music API calls
- **Swift Log**: Structured logging
- **Swift Argument Parser**: CLI argument parsing

## License

[Add your license information here]

## Contributing

[Add contribution guidelines here]