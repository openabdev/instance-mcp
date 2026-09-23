import Foundation
import CoreGraphics
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

/// One-shot screen capture via ScreenCaptureKit, returned as an MCP image block so the
/// model sees it directly. Needs the Screen Recording TCC grant for this binary's
/// signature; without it `SCShareableContent` throws and we return a clear error.
public struct ScreenshotTool: Tool {
    public let name = "screenshot"
    public let description = """
        Capture the current screen of this Mac and return it as an image. Use `display` \
        (0-based index, default 0 = main) on multi-monitor setups. `scale` downsamples \
        (default 0.5 — a Retina display at 1.0 is ~4x the pixels and rarely worth it). \
        `format` jpeg (default, `quality` 0–1) or png. Coordinates reported in `structuredContent` \
        are in display points, which is what mouse/keyboard tools will expect.
        """
    public let inputSchema: JSONValue = [
        "type": "object",
        "properties": [
            "display": ["type": "integer", "description": "Display index, 0 = main.", "default": 0],
            "scale": ["type": "number", "description": "Output scale relative to the display's pixel size. Default 0.5.", "minimum": 0.1, "maximum": 1.0],
            "format": ["type": "string", "enum": ["jpeg", "png"], "default": "jpeg"],
            "quality": ["type": "number", "description": "JPEG quality 0–1. Default 0.7.", "minimum": 0.1, "maximum": 1.0],
        ],
    ]

    public init() {}

    public func call(arguments: JSONValue) async throws -> ToolResult {
        let index = arguments["display"]?.intValue ?? 0
        let scale = min(max(arguments["scale"]?.doubleValue ?? 0.5, 0.1), 1.0)
        let format = arguments["format"]?.stringValue ?? "jpeg"
        let quality = min(max(arguments["quality"]?.doubleValue ?? 0.7, 0.1), 1.0)

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw ToolError("ScreenCaptureKit unavailable: \(error.localizedDescription). " +
                            "Grant Screen Recording to oab-mc-agent in System Settings → Privacy & Security, then restart the agent.")
        }
        let displays = content.displays.sorted { $0.displayID < $1.displayID }
        // Put the main display first so index 0 is predictable.
        let ordered = displays.sorted { a, b in
            (a.displayID == CGMainDisplayID() ? 0 : 1) < (b.displayID == CGMainDisplayID() ? 0 : 1)
        }
        guard index >= 0, index < ordered.count else {
            throw ToolError("display \(index) out of range; \(ordered.count) display(s) available")
        }
        let display = ordered[index]

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let cfg = SCStreamConfiguration()
        let pixelW = Int(Double(display.width) * filter.pointPixelScale.doubleValueOrOne * scale)
        let pixelH = Int(Double(display.height) * filter.pointPixelScale.doubleValueOrOne * scale)
        cfg.width = max(pixelW, 1)
        cfg.height = max(pixelH, 1)
        cfg.showsCursor = true
        cfg.captureResolution = .best

        let image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
        } catch {
            throw ToolError("capture failed: \(error.localizedDescription)")
        }

        let (data, mime) = try Self.encode(image, format: format, quality: quality)
        let structured: JSONValue = [
            "display": .number(Double(index)),
            "display_id": .number(Double(display.displayID)),
            "points": ["width": .number(Double(display.width)), "height": .number(Double(display.height))],
            "image": ["width": .number(Double(image.width)), "height": .number(Double(image.height)), "bytes": .number(Double(data.count))],
            "scale": .number(scale),
        ]
        let caption = "display \(index): \(display.width)×\(display.height) pt → \(image.width)×\(image.height) px \(mime) (\(data.count / 1024) KiB)"
        return ToolResult(content: [.image(data: data, mimeType: mime), .text(caption)], structured: structured)
    }

    static func encode(_ image: CGImage, format: String, quality: Double) throws -> (Data, String) {
        let type: UTType = format == "png" ? .png : .jpeg
        let mime = format == "png" ? "image/png" : "image/jpeg"
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil) else {
            throw ToolError("image encoder unavailable")
        }
        let props: [CFString: Any] = format == "png" ? [:] : [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ToolError("image encode failed") }
        return (out as Data, mime)
    }
}

private extension Float {
    var doubleValueOrOne: Double { self > 0 ? Double(self) : 1 }
}
