import Foundation

/// Just enough HTTP/1.1 for a loopback MCP endpoint behind `tailscale serve`:
/// one request per read loop, Content-Length bodies, no chunked request bodies,
/// no pipelining. Anything else is answered 4xx by the server.
public struct HTTPRequest: Equatable, Sendable {
    public var method: String
    public var path: String          // without query
    public var query: String?
    public var headers: [String: String]   // keys lowercased
    public var body: Data

    public func header(_ name: String) -> String? { headers[name.lowercased()] }
}

public enum HTTPParseResult: Equatable, Sendable {
    case incomplete                  // need more bytes
    case request(HTTPRequest, consumed: Int)
    case invalid(String)
}

public enum HTTPParser {
    public static let maxHeaderBytes = 64 * 1024
    public static let maxBodyBytes = 8 * 1024 * 1024

    public static func parse(_ buf: Data) -> HTTPParseResult {
        guard let headEnd = buf.range(of: Data("\r\n\r\n".utf8)) else {
            return buf.count > maxHeaderBytes ? .invalid("header too large") : .incomplete
        }
        let head = buf[buf.startIndex..<headEnd.lowerBound]
        guard let headStr = String(data: head, encoding: .utf8) else { return .invalid("non-UTF8 header") }
        var lines = headStr.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return .invalid("empty request") }
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: false)
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else {
            return .invalid("bad request line")
        }
        let method = String(requestLine[0])
        let target = String(requestLine[1])
        var path = target, query: String? = nil
        if let q = target.firstIndex(of: "?") {
            path = String(target[..<q]); query = String(target[target.index(after: q)...])
        }

        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { return .invalid("bad header line") }
            let k = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let v = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[k] = v
        }

        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            return .invalid("chunked request bodies not supported")
        }
        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard length >= 0 else { return .invalid("bad Content-Length") }
        guard length <= maxBodyBytes else { return .invalid("body too large") }

        let bodyStart = headEnd.upperBound
        let available = buf.endIndex - bodyStart
        guard available >= length else { return .incomplete }
        let body = Data(buf[bodyStart..<(bodyStart + length)])
        let consumed = (bodyStart - buf.startIndex) + length
        return .request(HTTPRequest(method: method, path: path, query: query, headers: headers, body: body), consumed: consumed)
    }
}

public struct HTTPResponse: Sendable {
    public var status: Int
    public var headers: [(String, String)]
    public var body: Data

    public init(status: Int, headers: [(String, String)] = [], body: Data = Data()) {
        self.status = status; self.headers = headers; self.body = body
    }

    public static func json(_ status: Int, _ value: some Encodable) -> HTTPResponse {
        let data = (try? JSONCoding.encoder.encode(value)) ?? Data("{}".utf8)
        return .init(status: status, headers: [("Content-Type", "application/json")], body: data)
    }

    public static func text(_ status: Int, _ s: String) -> HTTPResponse {
        .init(status: status, headers: [("Content-Type", "text/plain; charset=utf-8")], body: Data(s.utf8))
    }

    static func reason(_ s: Int) -> String {
        switch s {
        case 200: return "OK"; case 202: return "Accepted"; case 204: return "No Content"
        case 400: return "Bad Request"; case 401: return "Unauthorized"; case 403: return "Forbidden"
        case 404: return "Not Found"; case 405: return "Method Not Allowed"
        case 406: return "Not Acceptable"; case 413: return "Payload Too Large"
        case 415: return "Unsupported Media Type"; case 500: return "Internal Server Error"
        default: return "Status"
        }
    }

    public func serialize(keepAlive: Bool) -> Data {
        var s = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        for (k, v) in headers { s += "\(k): \(v)\r\n" }
        s += "Content-Length: \(body.count)\r\n"
        s += "Connection: \(keepAlive ? "keep-alive" : "close")\r\n\r\n"
        var d = Data(s.utf8); d.append(body); return d
    }
}
