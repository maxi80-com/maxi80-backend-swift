import AWSLambdaEvents
import AWSLambdaRuntime
import Logging
import Maxi80Backend
import Routing
import class SotoCore.AWSClient
import struct SotoCore.Region

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

@main
struct Maxi80Lambda: LambdaHandler {

    private let router: Maxi80Router

    init(
        s3Client: (any S3ManagerProtocol)? = nil,
        logger: Logger? = nil
    ) async throws {

        self.router = await withLogger(logger ?? LoggingConfiguration().makeRuntimeLogger()) { logger in
            logger.info("Initializing Maxi80Lambda...")

            // read the region from the environment variable
            let region = Lambda.env("AWS_REGION").flatMap { Region(awsRegionName: $0) } ?? .eucentral1
            logger.trace("Region: \(region)")

            // S3 configuration
            let bucket = Lambda.env("S3_BUCKET") ?? "artwork.maxi80.com"
            let keyPrefix = Lambda.env("KEY_PREFIX") ?? "v2"
            let urlExpiration = TimeInterval(Lambda.env("URL_EXPIRATION").flatMap { Int($0) } ?? 3600)

            let resolvedS3Client: any S3ManagerProtocol
            if let provided = s3Client {
                resolvedS3Client = provided
            } else {
                // One AWSClient (soto) using the Lambda execution role; reused across invocations.
                let awsClient = AWSClient()
                // Resolve actual bucket region (may differ from Lambda's region)
                let bucketRegion = await resolveBucketRegion(
                    bucket: bucket, client: awsClient, configuredRegion: region
                )
                logger.debug("Bucket \(bucket) resolved to region: \(bucketRegion)")
                resolvedS3Client = S3Manager(client: awsClient, region: bucketRegion)
            }

            let station = StationAction()
            let artwork = ArtworkAction(
                s3Client: resolvedS3Client,
                bucket: bucket,
                keyPrefix: keyPrefix,
                urlExpiration: urlExpiration
            )
            let history = HistoryAction(
                s3Client: resolvedS3Client,
                bucket: bucket,
                keyPrefix: keyPrefix
            )

            return Maxi80Router(station: station, artwork: artwork, history: history)
        }
    }

    func handle(_ event: APIGatewayV2Request, context: LambdaContext) async throws -> APIGatewayV2Response {
        context.logger.trace("HTTP API Message received")

        let response = await router.handle(HTTPRequest(event: event), logger: context.logger)
        return APIGatewayV2Response(
            statusCode: response.statusCode,
            headers: response.headers,
            body: response.body
        )
    }

    public static func main() async throws {
        let handler = try await Maxi80Lambda()
        let runtime = LambdaRuntime(lambdaHandler: handler)
        try await runtime.run()
    }
}
