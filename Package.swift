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

// Relaxed settings for the code-generated Soto service clients. The generator does not emit code
// that satisfies our strict upcoming-feature flags (ExistentialAny, InternalImportsByDefault,
// MemberImportVisibility) or warnings-as-errors, so those are omitted here.
let sotoSwiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault")
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
        .package(url: "https://github.com/soto-project/soto-core.git", from: "7.13.0"),
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.34.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.0"),
        // Fork of SongShift/lambda-kit widening the swift-aws-lambda-runtime pin to 3.x
        // (upstream pins 2.6.x, which conflicts with this project's 3.0.0-rc1). Only the
        // Routing library is used; it does not depend on the runtime. Track upstream and
        // switch back once it supports runtime 3.x. Package.resolved pins the commit.
        .package(url: "https://github.com/sebsto/lambda-kit.git", branch: "support-runtime-3"),
    ],
    targets: [
        // Minimal, code-generated AWS service clients (soto-codegenerator), each depending only on
        // SotoCore. Regenerate with scripts/generate-soto-services.sh. These replace aws-sdk-swift,
        // whose aws-crt TLS layer crashed at Lambda cold start (SDKDefaultIO.swift:77).
        .target(
            name: "SotoS3",
            dependencies: [.product(name: "SotoCore", package: "soto-core")],
            path: "Sources/Soto/S3",
            swiftSettings: sotoSwiftSettings
        ),
        .target(
            name: "SotoSSM",
            dependencies: [.product(name: "SotoCore", package: "soto-core")],
            path: "Sources/Soto/SSM",
            swiftSettings: sotoSwiftSettings
        ),
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
                .product(name: "Routing", package: "lambda-kit"),
                .target(name: "SotoS3"),
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
                .target(name: "SotoS3"),
                .target(name: "SotoSSM"),
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
                .target(name: "SotoS3"),
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
                .product(name: "Routing", package: "lambda-kit"),
                .product(name: "SotoCore", package: "soto-core"),
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
