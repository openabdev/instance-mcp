import Foundation

/// One MCP content block. Only the two kinds this daemon emits.
public enum ToolContent: Equatable, Sendable {
    case text(String)
    case image(data: Data, mimeType: String)

    public var json: JSONValue {
        switch self {
        case .text(let s):
            return ["type": "text", "text": .string(s)]
        case .image(let d, let mime):
            return ["type": "image", "data": .string(d.base64EncodedString()), "mimeType": .string(mime)]
        }
    }
}

public struct ToolResult: Equatable, Sendable {
    public var content: [ToolContent]
    public var isError: Bool
    /// Optional machine-readable payload, surfaced as `structuredContent` (MCP 2025-06-18).
    public var structured: JSONValue?

    public init(content: [ToolContent], isError: Bool = false, structured: JSONValue? = nil) {
        self.content = content; self.isError = isError; self.structured = structured
    }

    public static func text(_ s: String, structured: JSONValue? = nil) -> ToolResult {
        .init(content: [.text(s)], structured: structured)
    }
    public static func error(_ s: String) -> ToolResult {
        .init(content: [.text(s)], isError: true)
    }

    public var json: JSONValue {
        var o: [String: JSONValue] = ["content": .array(content.map(\.json))]
        if isError { o["isError"] = true }
        if let s = structured { o["structuredContent"] = s }
        return .object(o)
    }
}

public struct ToolError: Error, CustomStringConvertible {
    public var description: String
    public init(_ d: String) { description = d }
}

/// A tool the MCP server exposes. Implementations must be safe to call concurrently.
public protocol Tool: Sendable {
    var name: String { get }
    var description: String { get }
    /// JSON Schema for `arguments`.
    var inputSchema: JSONValue { get }
    func call(arguments: JSONValue) async throws -> ToolResult
}

extension Tool {
    public var descriptor: JSONValue {
        ["name": .string(name), "description": .string(description), "inputSchema": inputSchema]
    }
}
