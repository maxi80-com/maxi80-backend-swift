// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let defaultSwiftSettings: [SwiftSetting] =
    [
        .treatAllWarnings(as: .error),
        .enableExperimentalFeature("AvailabilityMacro=LambdaSwift 2.0:macOS 15.0"),

        // https://docs.swift.org/compiler/documentation/diagnostics/nonisolated-nonsending-by-default/
        .enableUpcomingFeature("NonisolatedNonsendingByDefault"),

        // https://github.com/apple/swift-evolution/blob/main/proposals/0335-existential-any.md
        // Require `any` for existential types
        .enableUpcomingFeature("ExistentialAny"),

        // https://github.com/swiftlang/swift-evolution/blob/main/proposals/0444-member-import-visibility.md
        .enableUpcomingFeature("MemberImportVisibility"),

        // https://github.com/swiftlang/swift-evolution/blob/main/proposals/0409-access-level-on-imports.md
        .enableUpcomingFeature("InternalImportsByDefault"),
    ]

let package = Package(
    name: "maxi-80-backend-swift",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "Maxi80Lambda", targets: ["Maxi80Lambda"]),
        .executable(name: "AuthorizerLambda", targets: ["AuthorizerLambda"]),
        .library(name: "Maxi80Backend", targets: ["Maxi80Backend"]),
        .executable(name: "Maxi80CLI", targets: ["Maxi80CLI"]),
        .executable(name: "ParseMetadata", targets: ["ParseMetadata"]),
        .executable(name: "CollectAppleMusic", targets: ["CollectAppleMusic"]),
        .executable(name: "IcecastMetadataCollector", targets: ["IcecastMetadataCollector"]),
    ],
    dependencies: [
        .package(url: "https://github.com/awslabs/swift-aws-lambda-runtime", from: "3.0.0-rc1"),
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
            ],
            swiftSettings: defaultSwiftSettings
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
            ],
            swiftSettings: defaultSwiftSettings
        ),
        .executableTarget(
            name: "Maxi80CLI",
            dependencies: [
                "Maxi80Backend",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: defaultSwiftSettings
        ),
        .executableTarget(
            name: "ParseMetadata",
            dependencies: ["Maxi80Backend"],
            swiftSettings: defaultSwiftSettings
        ),
        .executableTarget(
            name: "CollectAppleMusic",
            dependencies: ["Maxi80Backend"],
            swiftSettings: defaultSwiftSettings
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
            ],
            swiftSettings: defaultSwiftSettings
        ),
        .executableTarget(
            name: "AuthorizerLambda",
            dependencies: [
                .product(name: "AWSLambdaRuntime", package: "swift-aws-lambda-runtime"),
                .product(name: "AWSLambdaEvents", package: "swift-aws-lambda-events"),
                .product(
                    name: "Logging",
                    package: "swift-log",
                    condition: .when(platforms: [.linux, .macOS])
                ),
                .target(name: "Maxi80Backend"),
            ],
            swiftSettings: defaultSwiftSettings
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
            ],
            swiftSettings: defaultSwiftSettings
        ),
    ]
)
