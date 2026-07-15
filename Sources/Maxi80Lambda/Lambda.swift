import AWSLambdaEvents
import AWSLambdaRuntime
import AWSS3
import HTTPTypes
import Logging
import Maxi80Backend

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

@main
struct Maxi80Lambda: LambdaHandler {

    private let router: Router

    init(
        s3Client: (any S3ManagerProtocol)? = nil,
        logger: Logger? = nil
    ) async throws {

        self.router = try await withLogger(logger ?? LoggingConfiguration().makeRuntimeLogger()) { logger in
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
                // Resolve actual bucket region (may differ from Lambda's region)
                let bucketRegion = await resolveBucketRegion(bucket: bucket, configuredRegion: region)
                logger.debug("Bucket \(bucket) resolved to region: \(bucketRegion)")

                let s3Config = try await S3Client.S3ClientConfig(region: bucketRegion.rawValue)
                let s3 = S3Client(config: s3Config)
                resolvedS3Client = S3Manager(s3Client: s3, region: bucketRegion)
            }

            // Initialize actions array
            let actions: [any Action] = [
                StationAction(),
                ArtworkAction(
                    s3Client: resolvedS3Client,
                    bucket: bucket,
                    keyPrefix: keyPrefix,
                    urlExpiration: urlExpiration
                ),
                HistoryAction(
                    s3Client: resolvedS3Client,
                    bucket: bucket,
                    keyPrefix: keyPrefix
                ),
            ]

            // Initialize router with actions
            return Router(actions: actions)
        }
    }

    // the return value must be either APIGatewayV2Response or any Encodable struct
    func handle(_ event: APIGatewayV2Request, context: LambdaContext) async throws -> APIGatewayV2Response {
        var header = HTTPHeaders()
        header["content-type"] = "application/json"

        do {
            context.logger.trace("HTTP API Message received")

            // Route the request to get the action
            let action = try router.route(event, logger: context.logger).get()
            context.logger.trace("Action identified: \(action)")

            // Execute the action
            let responseData = try await action.handle(event: event, logger: context.logger)

            if responseData.isEmpty {
                return APIGatewayV2Response(statusCode: .noContent)
            } else {
                return APIGatewayV2Response(
                    statusCode: .ok,
                    headers: header,
                    body: String(decoding: responseData, as: UTF8.self)
                )
            }

        } catch let error as RouterError {
            return APIGatewayV2Response(
                statusCode: error.statusCode,
                headers: header,
                body: error.description
            )
        } catch let error as ActionError {
            return APIGatewayV2Response(
                statusCode: .badRequest,
                headers: header,
                body: error.description
            )
        } catch {
            header["content-type"] = "text/plain"
            return APIGatewayV2Response(
                statusCode: .internalServerError,
                headers: header,
                body: "\(error)"
            )
        }
    }

    public static func main() async throws {
        let handler = try await Maxi80Lambda()
        let runtime = LambdaRuntime(lambdaHandler: handler)
        try await runtime.run()
    }
}
