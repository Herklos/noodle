import CoreGraphics
import ImageIO
@testable import NoodleCore
import UniformTypeIdentifiers
import XCTest
@testable import NoodleImagesTools

final class ImageToolProviderTests: XCTestCase {
    private let context = ToolCallContext(agentID: UUID(), workspace: URL(fileURLWithPath: "/"))
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func model(_ id: String, steps: Int = 2, guidance: Double = 0, size: Int = 512) -> ImageModel {
        ImageModel(id: id, name: id.capitalized, summary: "\(id) summary.", repository: "example/\(id)",
                   steps: steps, guidance: guidance, size: size, byteCount: 1)
    }

    private func library(_ models: [ImageModel], default id: String? = nil) -> @Sendable () -> ImageLibrary {
        { .init(models: models, defaultModel: id, weights: { URL(fileURLWithPath: "/weights/\($0)") }) }
    }

    /// A tiny PNG standing in for the helper's output.
    private static func png(width: Int = 8, height: Int = 4) throws -> Data {
        let canvas = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(canvas.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func call(_ provider: ImageToolProvider, _ arguments: [String: Any], output name: String = "out.png",
                      image: Data? = nil) async throws -> (result: [String: Any], file: URL) {
        let output = root.appendingPathComponent(name)
        FileManager.default.createFile(atPath: output.path, contents: nil)
        var files = [ToolFile(parameter: "output", access: .write, handle: try FileHandle(forWritingTo: output), path: name)]
        if let image {
            let input = root.appendingPathComponent("input-\(UUID().uuidString).png")
            try image.write(to: input)
            files.append(ToolFile(parameter: "image", access: .read, handle: try FileHandle(forReadingFrom: input), path: input.lastPathComponent))
        }
        let data = try await provider.call("generate", arguments: JSONSerialization.data(withJSONObject: arguments.merging(["output": name]) { $1 }),
                                           files: files, context: context)
        return (try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]), output)
    }

    private func text(_ result: [String: Any]) -> String {
        ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
    }

    func testWithoutAModelTheToolSaysWhereToDownloadOne() async throws {
        let provider = ImageToolProvider(library: library([]), generate: { _ in XCTFail("Nothing to run"); return Data() })
        let data = try await provider.tools(context: context)
        let tools = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let description = try XCTUnwrap(((tools["tools"] as? [[String: Any]])?.first)?["description"] as? String)
        XCTAssertTrue(description.contains("Settings > Tools > Image Generation"), description)

        let (result, _) = try await call(provider, ["prompt": "a cat"])
        XCTAssertEqual(result["isError"] as? Bool, true)
        XCTAssertTrue(text(result).contains("No image model is downloaded"), text(result))
    }

    func testUsesTheDefaultModelsTunedSettingsAndWritesTheImage() async throws {
        let png = try Self.png()
        let requests = Requests()
        let provider = ImageToolProvider(
            library: library([model("fast"), model("detailed", steps: 30, guidance: 5, size: 1024)], default: "detailed"),
            generate: { await requests.append($0); return png }, seed: { 42 })
        let (result, file) = try await call(provider, ["prompt": " a lighthouse at dusk ", "negative-prompt": "text"])
        XCTAssertEqual(result["isError"] as? Bool, false, text(result))
        let all = await requests.all
        let request = try XCTUnwrap(all.first)
        XCTAssertEqual(request, ImageGenerationRequest(weights: URL(fileURLWithPath: "/weights/detailed"), prompt: "a lighthouse at dusk",
                                                       negativePrompt: "text", steps: 30, guidance: 5, width: 1024, height: 1024, seed: 42))
        XCTAssertEqual((result["structuredContent"] as? [String: Any])?["seed"] as? Int, 42)
        let written = try Data(contentsOf: file)
        XCTAssertEqual(CGImageSourceGetType(try XCTUnwrap(CGImageSourceCreateWithData(written as CFData, nil))) as String?, UTType.png.identifier)
    }

    func testANamedModelSizeAndStepsOverrideTheDefaults() async throws {
        let requests = Requests()
        let png = try Self.png()
        let provider = ImageToolProvider(library: library([model("fast"), model("detailed", steps: 30, guidance: 5, size: 1024)], default: "detailed"),
                                         generate: { await requests.append($0); return png })
        let (result, file) = try await call(provider, ["prompt": "a fox", "model": "fast", "width": 700, "height": 5000, "steps": 0, "seed": 7],
                                            output: "fox.jpg")
        XCTAssertEqual(result["isError"] as? Bool, false, text(result))
        let all = await requests.all
        let request = try XCTUnwrap(all.first)
        XCTAssertEqual(request.weights.lastPathComponent, "fast")
        XCTAssertEqual([request.width, request.height, request.steps], [704, 1536, 1])
        XCTAssertEqual(request.seed, 7)
        let written = try Data(contentsOf: file)
        XCTAssertEqual(CGImageSourceGetType(try XCTUnwrap(CGImageSourceCreateWithData(written as CFData, nil))) as String?, UTType.jpeg.identifier)
    }

    func testARemovedDefaultFallsBackAndAnUnknownModelIsRefused() async throws {
        let requests = Requests()
        let png = try Self.png()
        let provider = ImageToolProvider(library: library([model("fast")], default: "gone"), generate: { await requests.append($0); return png })
        let (fallback, _) = try await call(provider, ["prompt": "a fox"])
        XCTAssertEqual(fallback["isError"] as? Bool, false, text(fallback))
        let (refused, _) = try await call(provider, ["prompt": "a fox", "model": "gone"], output: "other.png")
        XCTAssertEqual(refused["isError"] as? Bool, true)
        XCTAssertTrue(text(refused).contains("Downloaded: fast"), text(refused))
        let count = await requests.all.count
        XCTAssertEqual(count, 1)
    }

    /// A starting picture keeps its proportions at the model's size, and the strength leaves at least one step to run.
    func testAStartingImageIsSentAtTheModelsSizeWithItsProportions() async throws {
        let requests = Requests()
        let png = try Self.png()
        let provider = ImageToolProvider(library: library([model("fast")]), generate: { await requests.append($0); return png })
        let (result, _) = try await call(provider, ["prompt": "as a watercolour"], image: try Self.png(width: 800, height: 400))
        XCTAssertEqual(result["isError"] as? Bool, false, text(result))
        let all = await requests.all
        let request = try XCTUnwrap(all.first)
        XCTAssertEqual([request.width, request.height], [512, 256])
        XCTAssertEqual(request.strength, 0.6)
        XCTAssertEqual(request.steps, 2, "2 steps at 0.6 still run one")
        let input = try XCTUnwrap(request.image.flatMap { CGImageSourceCreateWithData($0 as CFData, nil) }.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        XCTAssertEqual([input.width, input.height], [512, 256])

        let (weak, _) = try await call(provider, ["prompt": "as a watercolour", "strength": 0.1], output: "weak.png",
                                       image: try Self.png(width: 300, height: 600))
        XCTAssertEqual(weak["isError"] as? Bool, false, text(weak))
        let last = await requests.all.last
        XCTAssertEqual(last?.strength, 0.1)
        XCTAssertEqual(last?.steps, 10, "Too few steps for that strength would run none")
        XCTAssertEqual([last?.width, last?.height], [256, 512])
    }

    /// Through the broker's own checks: a bot granted the tool may call generate, any other bot may not.
    func testTheBrokerRunsGenerateForAGrantedBotOnly() async throws {
        let provider = ImageToolProvider(library: library([]), generate: { _ in Data() })
        let data = try await provider.tools(context: context)
        let descriptor = try XCTUnwrap(ToolDescriptor.list(mcp: data).first { $0.name == "generate" })
        let arguments = try JSONSerialization.data(withJSONObject: ["prompt": "a bird", "output": "bird.png"])
        let granted: ToolAssignments = [ImageGenerationSettings.kind: ["default"]]
        XCTAssertNoThrow(try ToolBroker.authorize(descriptor, provider: provider.manifest, arguments: arguments, assignments: granted))
        let registry = ToolProviderRegistry()
        try registry.register(provider)
        XCTAssertNoThrow(try registry.provider("images", assignments: granted))
        XCTAssertThrowsError(try registry.provider("images", assignments: .none))
    }
}

private actor Requests {
    var all: [ImageGenerationRequest] = []
    func append(_ request: ImageGenerationRequest) { all.append(request) }
}
