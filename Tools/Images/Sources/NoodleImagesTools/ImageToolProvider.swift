import Foundation
import ImageIO
import NoodleCore
import UniformTypeIdentifiers

/// Image generation on this Mac. Noodle grants it per bot in the bot editor; which models are
/// downloaded and which is the default is decided once, in Settings > Tools, and read on every call.
public struct ImageToolProvider: ToolProvider {
    public let kind = ToolProviderKind.builtIn
    public let manifest = ToolProviderManifest(
        id: "images", title: "Image Generation", summary: "Make images from a text description, on this Mac.",
        instructions: """
        generate makes one image from --prompt and writes it to the workspace file you pass as --output; its extension picks the format, such as .png or .jpg. \
        It runs on this Mac and nothing is sent anywhere. Expect a few seconds to a few minutes, depending on the model and size.

        Describe the picture in --prompt as comma-separated visual details: subject, setting, style, lighting, composition. \
        Put what to leave out in --negative-prompt, such as "blurry, text, watermark". \
        Leave --model, --steps and the size out unless you were asked for them; the person's chosen model and its tuned settings are used.

        To change an existing picture, pass it as --image with a prompt describing the result. --strength sets how much is reworked: \
        0.3 keeps the layout and colours and restyles it, 0.6 (the default) keeps the composition, 0.9 keeps little more than the idea. \
        The result keeps the picture's proportions unless you set the size. It cannot change only one area of a picture.

        The result gives the seed. Pass the same --seed with a changed prompt to vary an image while keeping its composition. \
        To show the image to the person, send the file as an attachment.
        """,
        // Granted as a whole: generate names no resource, so the broker checks the grant around each call.
        activation: .whenGranted(ImageGenerationSettings.kind, id: "default"))

    private let library: @Sendable () -> ImageLibrary
    private let generate: @Sendable (ImageGenerationRequest) async throws -> Data
    private let seed: @Sendable () -> UInt64

    public init(library: @escaping @Sendable () -> ImageLibrary, generate: @escaping @Sendable (ImageGenerationRequest) async throws -> Data,
                seed: @escaping @Sendable () -> UInt64 = { UInt64.random(in: 0..<(1 << 32)) }) {
        self.library = library; self.generate = generate; self.seed = seed
    }

    public func tools(context: ToolCallContext) async throws -> Data {
        let library = library()
        let models = library.models
        var model: [String: Any] = ["type": "string"]
        if models.isEmpty {
            model["description"] = "No image model is downloaded yet."
        } else {
            model["enum"] = models.map(\.id)
            model["description"] = "Model to use instead of the default, \(library.current?.id ?? ""). "
                + models.map { "\($0.id): \($0.summary)" }.joined(separator: " ")
        }
        let tool: [String: Any] = [
            "name": "generate",
            "description": models.isEmpty
                ? "Make an image from a description. No model is downloaded yet; the person can download one in Noodle's Settings > Tools > Image Generation."
                : "Make an image from a description, or rework a picture you pass as --image, and write it to a workspace file.",
            "annotations": ["readOnlyHint": false, "idempotentHint": true],
            "_meta": ["noodle/timeout": 900],
            "inputSchema": ["type": "object", "required": ["prompt", "output"], "properties": [
                "prompt": ["type": "string", "description": "What the image shows."],
                "output": ["type": "string", "format": "noodle-file", "noodle/access": "write",
                           "description": "Workspace file to write, such as image.png; its extension picks the format."],
                "negative-prompt": ["type": "string", "description": "What to keep out of the image."],
                "image": ["type": "string", "format": "noodle-file", "description": "Picture in your workspace to start from instead of noise."],
                "strength": ["type": "number", "description": "With --image: how much to rework it, 0.05–1. Default 0.6."],
                "model": model,
                "width": ["type": "integer", "description": "Width in pixels, 256–1536, rounded to a multiple of 64. Defaults to the model's size, or the --image proportions at that size."],
                "height": ["type": "integer", "description": "Height in pixels, 256–1536, rounded to a multiple of 64. Defaults to the model's size, or the --image proportions at that size."],
                "steps": ["type": "integer", "description": "Denoising steps, 1–100. More is slower and only sometimes better. Defaults to the model's tuned value."],
                "seed": ["type": "integer", "description": "Seed for a repeatable result. Random when omitted."]]]]
        return try JSONSerialization.data(withJSONObject: ["tools": [tool]], options: [.sortedKeys])
    }

    public func call(_ tool: String, arguments: Data, files: [ToolFile], context: ToolCallContext) async throws -> Data {
        do {
            guard tool == "generate" else { throw ToolProviderError("Image Generation has no tool named \(tool).") }
            let options = (try? JSONSerialization.jsonObject(with: arguments)) as? [String: Any] ?? [:]
            guard let prompt = (options["prompt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty else {
                throw ToolProviderError("Describe the image with --prompt.")
            }
            guard let output = files.first(where: { $0.parameter == "output" && $0.access == .write }) else {
                throw ToolProviderError("Specify --output with a workspace file to write.")
            }
            let path = options["output"] as? String ?? output.path
            let writable = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
            guard let type = UTType(filenameExtension: (path as NSString).pathExtension), type.conforms(to: .image),
                  writable.contains(type.identifier) else {
                throw ToolProviderError("Name --output with an image extension such as .png or .jpg.")
            }
            let library = library()
            guard let fallback = library.current else {
                throw ToolProviderError("No image model is downloaded yet. Ask the person to download one in Noodle's Settings > Tools > Image Generation.")
            }
            let model: ImageModel
            if let name = options["model"] as? String {
                guard let chosen = library.models.first(where: { $0.id == name }) else {
                    throw ToolProviderError("There is no downloaded image model named \(name). Downloaded: \(library.models.map(\.id).joined(separator: ", ")).")
                }
                model = chosen
            } else { model = fallback }
            let start = try files.first { $0.parameter == "image" }.map(Self.upright)
            func edge(_ key: String, _ fallback: Double) -> Int {
                let value = min(max(Double(options[key] as? Int ?? Int(fallback.rounded())), 256), 1536)
                return Int((value / 64).rounded()) * 64
            }
            // A starting picture keeps its proportions, with its longer side at the model's size.
            let scale = start.map { Double(model.size) / Double(max($0.width, $0.height)) } ?? 1
            let width = edge("width", start.map { Double($0.width) * scale } ?? Double(model.size))
            let height = edge("height", start.map { Double($0.height) * scale } ?? Double(model.size))
            let strength = start == nil ? 1 : min(max(options["strength"] as? Double ?? 0.6, 0.05), 1)
            // The model runs steps × strength of them, so a light touch needs more to run any.
            let steps = max(min(max(options["steps"] as? Int ?? model.steps, 1), 100), Int((1 / strength).rounded(.up)))
            let seed = (options["seed"] as? Int).map { UInt64(truncatingIfNeeded: $0) } ?? seed()
            let request = ImageGenerationRequest(
                weights: try library.weights(model.id), prompt: prompt,
                negativePrompt: (options["negative-prompt"] as? String) ?? "",
                steps: steps, guidance: model.guidance, width: width, height: height, seed: seed,
                image: try start.map { try Self.png($0, width: width, height: height) }, strength: strength)
            let png = try await generate(request)
            guard let source = CGImageSourceCreateWithData(png as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw ToolProviderError("The model did not return an image.")
            }
            let encoded = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(encoded, type.identifier as CFString, 1, nil) else {
                throw ToolProviderError("This Mac cannot write \(type.localizedDescription ?? type.identifier) images.")
            }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw ToolProviderError("The image could not be encoded.") }
            // Writing over the bot's file cannot be taken back.
            try await context.authorize()
            try output.handle.truncate(atOffset: 0)
            try output.handle.write(contentsOf: encoded as Data)
            try output.handle.synchronize()
            let structured: [String: Any] = ["path": path, "model": model.id, "width": image.width, "height": image.height,
                                             "steps": request.steps, "seed": seed, "bytes": encoded.length]
            return try JSONSerialization.data(withJSONObject: [
                "content": [["type": "text", "text": "Wrote a \(image.width)×\(image.height) image to \(path) with \(model.name), seed \(seed)."]],
                "structuredContent": structured, "isError": false], options: [.sortedKeys])
        } catch {
            return try JSONSerialization.data(withJSONObject: ["content": [["type": "text", "text": error.localizedDescription]], "isError": true],
                                              options: [.sortedKeys])
        }
    }

    /// The bot's picture turned upright, as it shows in a viewer.
    private static func upright(_ file: ToolFile) throws -> CGImage {
        guard let data = try file.handle.readToEnd(), let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 4096] as CFDictionary) else {
            throw ToolProviderError("The --image file could not be decoded.")
        }
        return image
    }

    /// Scaled to fill the size the model works at, trimming the edges where the proportions differ.
    private static func png(_ image: CGImage, width: Int, height: Int) throws -> Data {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let canvas = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                     bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw ToolProviderError("The --image file could not be prepared.")
        }
        let scale = max(Double(width) / Double(image.width), Double(height) / Double(image.height))
        let drawn = CGSize(width: Double(image.width) * scale, height: Double(image.height) * scale)
        canvas.setFillColor(gray: 1, alpha: 1)
        canvas.fill(CGRect(x: 0, y: 0, width: width, height: height))
        canvas.interpolationQuality = .high
        canvas.draw(image, in: CGRect(x: (Double(width) - drawn.width) / 2, y: (Double(height) - drawn.height) / 2,
                                      width: drawn.width, height: drawn.height))
        let data = NSMutableData()
        guard let prepared = canvas.makeImage(),
              let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw ToolProviderError("The --image file could not be prepared.")
        }
        CGImageDestinationAddImage(destination, prepared, nil)
        guard CGImageDestinationFinalize(destination) else { throw ToolProviderError("The --image file could not be prepared.") }
        return data as Data
    }
}
