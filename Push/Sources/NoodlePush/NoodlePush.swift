import Foundation
import HTTPTypes
import Hummingbird
import Logging
import PushCore

/// The server the container runs. The Worker in `worker/` forwards every request here on port 8080.
@main
struct NoodlePush {
    static func main() async throws {
        LoggingSystem.bootstrap(StreamLogHandler.standardOutput)
        var logger = Logger(label: "noodle-push")
        logger.logLevel = .info

        let configuration: PushConfiguration
        do {
            configuration = try PushConfiguration(environment: ProcessInfo.processInfo.environment)
        } catch {
            // Names the missing or malformed variable only, never a value.
            logger.critical("Cannot start: \(error)")
            exit(1)
        }
        let sender = APNsVoIPSender(configuration: configuration)
        let service = PushService(sealer: try TokenSealer(key: configuration.sealKey), sender: sender,
                                  limits: configuration.limits, logger: logger)

        let router = Router()
        // The Worker's cron and the deploy job ping this to keep one instance warm.
        router.get("healthz") { _, _ in "ok" }
        router.post("v1/register") { request, context -> Response in
            let body = try await request.body.collect(upTo: 4_096)
            let address = request.headers[HTTPField.Name("X-Noodle-Client-IP")!] ?? "unknown"
            return response(await service.register(Data(body.readableBytesView), address: address))
        }
        router.post("v1/ring") { request, context -> Response in
            let body = try await request.body.collect(upTo: 16_384)
            let address = request.headers[HTTPField.Name("X-Noodle-Client-IP")!] ?? "unknown"
            return response(await service.ring(Data(body.readableBytesView), address: address))
        }

        let app = Application(router: router, configuration: .init(address: .hostname("0.0.0.0", port: configuration.port)),
                              logger: logger)
        try await app.runService()
        await sender.shutdown()
    }
}

private func response(_ answer: PushHTTPResponse) -> Response {
    Response(status: HTTPResponse.Status(code: answer.status), headers: [.contentType: "application/json"],
             body: ResponseBody(byteBuffer: ByteBuffer(bytes: answer.body)))
}
