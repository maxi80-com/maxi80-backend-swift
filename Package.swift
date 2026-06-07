// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "maxi-80-backend-swift",
    platforms: [
        .macOS(.v26),
    ],
    products: [
        .executable(name: "Maxi80Lambda", targets: ["Maxi80Lambda"]),
        .library(name: "Maxi80Backend", targets: ["Maxi80Backend"]),
        .executable(name: "Maxi80CLI", targets: ["Maxi80CLI"]),
        .executable(name: "ParseMetadata", targets: ["ParseMetadata"]),
        .executable(name: "CollectAppleMusic", targets: ["CollectAppleMusic"]),
        .executable(name: "IcecastMetadataCollector", targets: ["IcecastMetadataCollector"]),
    ],
    dependencies: [
        .package(url: "https://github.com/awslabs/swift-aws-lambda-runtime", from: "2.10.0"),
        .package(url: "https://github.com/awslabs/swift-aws-lambda-events.git", from: "1.5.0"),
        .package(url: "https://github.com/vapor/jwt-kit.git", from: "5.5.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.13.0"),
        .package(url: "https://github.com/awslabs/aws-sdk-swift.git", from: "1.7.0"),
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.34.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.0"),
    ],
    targets: [
        .executableTarget(
            name: "Maxi80Lambda",
            dependencies: [
                .product(name: "AWSLambdaRuntime", package: "swift-aws-lambda-runtime"),
                .product(name: "AWSLambdaEvents", package: "swift-aws-lambda-events"),
                .product(
                    name: "Logging",
                    package: "swift-log",
                    condition: .when(platforms: [.linux, .macOS])
                ),
                .product(name: "AWSS3", package: "aws-sdk-swift"),
                .target(name: "Maxi80Backend"),
            ]
        ),
        .target(
            name: "Maxi80Backend",
            dependencies: [
                .product(
                    name: "Logging",
                    package: "swift-log",
                    condition: .when(platforms: [.linux, .macOS])
                ),
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "JWTKit", package: "jwt-kit"),
                .product(name: "AWSSSM", package: "aws-sdk-swift"),
                .product(name: "AWSS3", package: "aws-sdk-swift"),
            ]
        ),
        .executableTarget(
            name: "Maxi80CLI",
            dependencies: [
                "Maxi80Backend",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(
            name: "ParseMetadata",
            dependencies: ["Maxi80Backend"]
        ),
        .executableTarget(
            name: "CollectAppleMusic",
            dependencies: ["Maxi80Backend"]
        ),
        .executableTarget(
            name: "IcecastMetadataCollector",
            dependencies: [
                .product(name: "AWSLambdaRuntime", package: "swift-aws-lambda-runtime"),
                .product(name: "AWSLambdaEvents", package: "swift-aws-lambda-events"),
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(
                    name: "Logging",
                    package: "swift-log",
                    condition: .when(platforms: [.linux, .macOS])
                ),
                .product(name: "AWSS3", package: "aws-sdk-swift"),
                .target(name: "Maxi80Backend"),
            ]
        ),
        .testTarget(
            name: "Maxi80BackendTests",
            dependencies: [
                "Maxi80Backend",
                "Maxi80Lambda",
                "IcecastMetadataCollector",
                .product(name: "AWSLambdaEvents", package: "swift-aws-lambda-events"),
                .product(
                    name: "Logging",
                    package: "swift-log",
                    condition: .when(platforms: [.linux, .macOS])
                ),
            ]
        ),
    ]
)
