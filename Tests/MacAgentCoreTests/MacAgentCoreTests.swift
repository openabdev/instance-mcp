import ApplicationServices
import XCTest
@testable import MacAgentCore

// MARK: - helpers

struct EchoTool: Tool {
    let name = "echo"
    let description = "echo"
    let inputSchema: JSONValue = ["type": "object"]
    func call(arguments: JSONValue) async throws -> ToolResult {
        if arguments["fail"]?.boolValue == true { throw ToolError("boom") }
        return .text(arguments["msg"]?.stringValue ?? "")
    }
}

func rpc(_ method: String, id: JSONValue? = 1, params: JSONValue? = nil) -> Data {
    var o: [String: JSONValue] = ["jsonrpc": "2.0", "method": .string(method)]
    if let id { o["id"] = id }
    if let params { o["params"] = params }
    return try! JSONCoding.encoder.encode(JSONValue.object(o))
}

func decodeJSON(_ d: Data) -> JSONValue { try! JSONCoding.decoder.decode(JSONValue.self, from: d) }

// MARK: - JSON-RPC

final class JSONRPCTests: XCTestCase {
    func testIntegerIdRoundTripsWithoutDecimal() throws {
        let r = JSONRPCResponse(id: 7, result: [:])
        let s = String(decoding: try JSONCoding.encoder.encode(r), as: UTF8.self)
        XCTAssertTrue(s.contains("\"id\":7"), s)
        XCTAssertFalse(s.contains("7.0"), s)
    }

    func testStringIdPreserved() {
        let req = try! JSONCoding.decoder.decode(JSONRPCRequest.self, from: rpc("ping", id: "abc"))
        XCTAssertEqual(req.id, "abc")
        XCTAssertFalse(req.isNotification)
    }

    func testNotificationHasNoId() {
        let req = try! JSONCoding.decoder.decode(JSONRPCRequest.self, from: rpc("notifications/initialized", id: nil))
        XCTAssertTrue(req.isNotification)
    }

    func testBatchRejected() {
        let r = MCPServer.parse(Data("[{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}]".utf8))
        guard case .failure(let e) = r else { return XCTFail("expected failure") }
        XCTAssertEqual(e.code, JSONRPCError.invalidRequest)
    }

    func testGarbageIsParseError() {
        guard case .failure(let e) = MCPServer.parse(Data("{nope".utf8)) else { return XCTFail() }
        XCTAssertEqual(e.code, JSONRPCError.parseError)
    }
}

// MARK: - MCP dispatch

final class MCPServerTests: XCTestCase {
    let server = MCPServer(name: "t", version: "0", tools: [EchoTool()])

    func testInitializeNegotiatesKnownVersion() async {
        let req = try! JSONCoding.decoder.decode(JSONRPCRequest.self, from: rpc("initialize", params: ["protocolVersion": "2025-03-26"]))
        let resp = await server.handle(req)!
        XCTAssertEqual(resp.result?["protocolVersion"]?.stringValue, "2025-03-26")
        XCTAssertEqual(resp.result?["serverInfo"]?["name"]?.stringValue, "t")
    }

    func testInitializeFallsBackForUnknownVersion() async {
        let req = try! JSONCoding.decoder.decode(JSONRPCRequest.self, from: rpc("initialize", params: ["protocolVersion": "1999-01-01"]))
        let resp = await server.handle(req)!
        XCTAssertEqual(resp.result?["protocolVersion"]?.stringValue, MCPServer.protocolVersion)
    }

    func testToolsList() async {
        let req = try! JSONCoding.decoder.decode(JSONRPCRequest.self, from: rpc("tools/list"))
        let resp = await server.handle(req)!
        XCTAssertEqual(resp.result?["tools"]?.arrayValue?.first?["name"]?.stringValue, "echo")
    }

    func testToolsCall() async {
        let req = try! JSONCoding.decoder.decode(JSONRPCRequest.self, from: rpc("tools/call", params: ["name": "echo", "arguments": ["msg": "hi"]]))
        let resp = await server.handle(req)!
        XCTAssertEqual(resp.result?["content"]?.arrayValue?.first?["text"]?.stringValue, "hi")
        XCTAssertNil(resp.result?["isError"])
    }

    func testToolErrorBecomesIsErrorResultNotRPCError() async {
        let req = try! JSONCoding.decoder.decode(JSONRPCRequest.self, from: rpc("tools/call", params: ["name": "echo", "arguments": ["fail": true]]))
        let resp = await server.handle(req)!
        XCTAssertNil(resp.error)
        XCTAssertEqual(resp.result?["isError"]?.boolValue, true)
        XCTAssertEqual(resp.result?["content"]?.arrayValue?.first?["text"]?.stringValue, "boom")
    }

    func testUnknownToolIsInvalidParams() async {
        let req = try! JSONCoding.decoder.decode(JSONRPCRequest.self, from: rpc("tools/call", params: ["name": "nope"]))
        let resp = await server.handle(req)!
        XCTAssertEqual(resp.error?.code, JSONRPCError.invalidParams)
    }

    func testUnknownMethod() async {
        let req = try! JSONCoding.decoder.decode(JSONRPCRequest.self, from: rpc("wat"))
        let resp = await server.handle(req)!
        XCTAssertEqual(resp.error?.code, JSONRPCError.methodNotFound)
    }

    func testNotificationProducesNoResponse() async {
        let req = try! JSONCoding.decoder.decode(JSONRPCRequest.self, from: rpc("notifications/initialized", id: nil))
        let resp = await server.handle(req)
        XCTAssertNil(resp)
    }
}

// MARK: - HTTP parser

final class HTTPParserTests: XCTestCase {
    func testIncompleteHeader() {
        XCTAssertEqual(HTTPParser.parse(Data("POST /mcp HTTP/1.1\r\nHost: x".utf8)), .incomplete)
    }

    func testIncompleteBody() {
        let d = Data("POST /mcp HTTP/1.1\r\nContent-Length: 5\r\n\r\nab".utf8)
        XCTAssertEqual(HTTPParser.parse(d), .incomplete)
    }

    func testFullRequestAndLeftover() {
        let d = Data("POST /mcp?x=1 HTTP/1.1\r\nHost: h\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}GET".utf8)
        guard case .request(let r, let consumed) = HTTPParser.parse(d) else { return XCTFail() }
        XCTAssertEqual(r.method, "POST")
        XCTAssertEqual(r.path, "/mcp")
        XCTAssertEqual(r.query, "x=1")
        XCTAssertEqual(r.header("content-type"), "application/json")
        XCTAssertEqual(r.body, Data("{}".utf8))
        XCTAssertEqual(d.count - consumed, 3)
    }

    func testHeaderKeysLowercased() {
        let d = Data("GET / HTTP/1.1\r\nTailscale-User-Login: A@B.com\r\n\r\n".utf8)
        guard case .request(let r, _) = HTTPParser.parse(d) else { return XCTFail() }
        XCTAssertEqual(r.headers["tailscale-user-login"], "A@B.com")
    }

    func testChunkedRejected() {
        let d = Data("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)
        guard case .invalid = HTTPParser.parse(d) else { return XCTFail() }
    }

    func testBadRequestLine() {
        guard case .invalid = HTTPParser.parse(Data("HELLO\r\n\r\n".utf8)) else { return XCTFail() }
    }

    func testResponseSerialization() {
        let r = HTTPResponse.json(200, JSONRPCResponse(id: 1, result: [:]))
        let s = String(decoding: r.serialize(keepAlive: true), as: UTF8.self)
        XCTAssertTrue(s.hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertTrue(s.contains("Content-Type: application/json\r\n"))
        XCTAssertTrue(s.contains("Connection: keep-alive\r\n"))
        XCTAssertTrue(s.hasSuffix("\r\n\r\n{\"id\":1,\"jsonrpc\":\"2.0\",\"result\":{}}"))
    }
}

// MARK: - Auth

final class AuthPolicyTests: XCTestCase {
    func testNoAuthConfiguredRefusesToValidate() {
        XCTAssertThrowsError(try AuthPolicy().validate())
        XCTAssertNoThrow(try AuthPolicy(allowedLogins: ["a@b"]).validate())
        XCTAssertNoThrow(try AuthPolicy(bearerToken: "t").validate())
        XCTAssertNoThrow(try AuthPolicy(allowLocalUnauthenticated: true).validate())
    }

    func testLoginAllowlistCaseInsensitive() {
        let p = AuthPolicy(allowedLogins: ["Pahud@Example.com"])
        XCTAssertEqual(p.decide(headers: ["tailscale-user-login": "pahud@example.com"], remoteIsLoopback: true), .allow(principal: "pahud@example.com"))
        XCTAssertEqual(p.decide(headers: ["tailscale-user-login": "other@example.com"], remoteIsLoopback: true), .deny(reason: "login other@example.com not allowed"))
    }

    func testLoginRequiredWhenAllowlistSet() {
        let p = AuthPolicy(allowedLogins: ["a@b"])
        // Loopback without tailscale headers is denied unless --insecure-local.
        if case .allow = p.decide(headers: [:], remoteIsLoopback: true) { XCTFail("must deny") }
        // With X-Forwarded-For but no login (a tailnet peer not logged in) → deny.
        if case .allow = p.decide(headers: ["x-forwarded-for": "100.1.2.3"], remoteIsLoopback: true) { XCTFail("must deny") }
    }

    func testInsecureLocalOnlyForBareLoopback() {
        let p = AuthPolicy(allowedLogins: ["a@b"], allowLocalUnauthenticated: true)
        XCTAssertEqual(p.decide(headers: [:], remoteIsLoopback: true), .allow(principal: "local"))
        // Came through tailscale serve (has X-Forwarded-For) → identity still required.
        if case .allow = p.decide(headers: ["x-forwarded-for": "100.1.2.3"], remoteIsLoopback: true) { XCTFail("must deny") }
        if case .allow = p.decide(headers: [:], remoteIsLoopback: false) { XCTFail("must deny non-loopback") }
    }

    func testBearerToken() {
        let p = AuthPolicy(bearerToken: "s3cret")
        XCTAssertEqual(p.decide(headers: ["authorization": "Bearer s3cret"], remoteIsLoopback: true), .allow(principal: "token"))
        XCTAssertEqual(p.decide(headers: ["authorization": "bearer s3cret"], remoteIsLoopback: true), .allow(principal: "token"))
        XCTAssertEqual(p.decide(headers: ["authorization": "Bearer nope"], remoteIsLoopback: true), .deny(reason: "bad token"))
        XCTAssertEqual(p.decide(headers: [:], remoteIsLoopback: true), .deny(reason: "missing Authorization header"))
        XCTAssertEqual(p.decide(headers: ["authorization": "Basic xx"], remoteIsLoopback: true), .deny(reason: "Authorization must be Bearer"))
    }

    func testBothRequiredWhenBothConfigured() {
        let p = AuthPolicy(allowedLogins: ["a@b"], bearerToken: "t")
        XCTAssertEqual(p.decide(headers: ["tailscale-user-login": "a@b", "authorization": "Bearer t"], remoteIsLoopback: true), .allow(principal: "a@b"))
        if case .allow = p.decide(headers: ["tailscale-user-login": "a@b"], remoteIsLoopback: true) { XCTFail("token missing must deny") }
        if case .allow = p.decide(headers: ["authorization": "Bearer t"], remoteIsLoopback: true) { XCTFail("login missing must deny") }
        if case .allow = p.decide(headers: ["tailscale-user-login": "x@y", "authorization": "Bearer t"], remoteIsLoopback: true) { XCTFail("wrong login must deny") }
    }
}

// MARK: - Endpoint (HTTP ↔ MCP glue)

final class EndpointTests: XCTestCase {
    func makeEndpoint() -> MCPHTTPEndpoint {
        MCPHTTPEndpoint(server: MCPServer(name: "t", version: "0", tools: [EchoTool()]),
                        auth: AuthPolicy(allowedLogins: ["a@b"]))
    }
    func post(_ body: Data, headers: [String: String] = [:]) -> HTTPRequest {
        var h = ["content-type": "application/json", "tailscale-user-login": "a@b", "x-forwarded-for": "100.1.1.1"]
        h.merge(headers) { _, b in b }
        return HTTPRequest(method: "POST", path: "/mcp", query: nil, headers: h, body: body)
    }

    func testUnauthenticatedIs401() async {
        let ep = makeEndpoint()
        let r = await ep.handle(HTTPRequest(method: "POST", path: "/mcp", query: nil, headers: ["content-type": "application/json"], body: rpc("ping")), remoteIsLoopback: true)
        XCTAssertEqual(r.status, 401)
    }

    func testHealthzNeedsNoAuth() async {
        let r = await makeEndpoint().handle(HTTPRequest(method: "GET", path: "/healthz", query: nil, headers: [:], body: Data()), remoteIsLoopback: true)
        XCTAssertEqual(r.status, 200)
    }

    func testWrongPath404() async {
        let r = await makeEndpoint().handle(post(rpc("ping")).with(path: "/x"), remoteIsLoopback: true)
        XCTAssertEqual(r.status, 404)
    }

    func testInitializeIssuesSessionAndSubsequentCallsUseIt() async {
        let ep = makeEndpoint()
        let init_ = await ep.handle(post(rpc("initialize", params: ["protocolVersion": "2025-06-18"])), remoteIsLoopback: true)
        XCTAssertEqual(init_.status, 200)
        let sid = init_.headers.first { $0.0 == "Mcp-Session-Id" }?.1
        XCTAssertNotNil(sid)

        let note = await ep.handle(post(rpc("notifications/initialized", id: nil), headers: ["mcp-session-id": sid!]), remoteIsLoopback: true)
        XCTAssertEqual(note.status, 202)
        XCTAssertTrue(note.body.isEmpty)

        let call = await ep.handle(post(rpc("tools/call", params: ["name": "echo", "arguments": ["msg": "x"]]), headers: ["mcp-session-id": sid!]), remoteIsLoopback: true)
        XCTAssertEqual(call.status, 200)
        XCTAssertEqual(decodeJSON(call.body)["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue, "x")

        let unknown = await ep.handle(post(rpc("ping"), headers: ["mcp-session-id": "nope"]), remoteIsLoopback: true)
        XCTAssertEqual(unknown.status, 404)

        let del = await ep.handle(HTTPRequest(method: "DELETE", path: "/mcp", query: nil, headers: ["tailscale-user-login": "a@b", "mcp-session-id": sid!], body: Data()), remoteIsLoopback: true)
        XCTAssertEqual(del.status, 204)
        let after = await ep.handle(post(rpc("ping"), headers: ["mcp-session-id": sid!]), remoteIsLoopback: true)
        XCTAssertEqual(after.status, 404)
    }

    func testGetIs405() async {
        let r = await makeEndpoint().handle(HTTPRequest(method: "GET", path: "/mcp", query: nil, headers: ["tailscale-user-login": "a@b"], body: Data()), remoteIsLoopback: true)
        XCTAssertEqual(r.status, 405)
    }

    func testWrongContentType415() async {
        let r = await makeEndpoint().handle(post(rpc("ping"), headers: ["content-type": "text/plain"]), remoteIsLoopback: true)
        XCTAssertEqual(r.status, 415)
    }

    func testMalformedJSON400WithRPCError() async {
        let r = await makeEndpoint().handle(post(Data("{".utf8)), remoteIsLoopback: true)
        XCTAssertEqual(r.status, 400)
        XCTAssertEqual(decodeJSON(r.body)["error"]?["code"]?.intValue, JSONRPCError.parseError)
    }
}

extension HTTPRequest {
    func with(path: String) -> HTTPRequest { var c = self; c.path = path; return c }
}

// MARK: - exec

final class ExecToolTests: XCTestCase {
    let tool = ExecTool()

    func testStdoutStderrExit() async throws {
        let r = try await tool.call(arguments: ["command": "echo out; echo err 1>&2; exit 3"])
        XCTAssertTrue(r.isError)
        XCTAssertEqual(r.structured?["exit_code"]?.intValue, 3)
        XCTAssertEqual(r.structured?["stdout"]?.stringValue, "out\n")
        XCTAssertEqual(r.structured?["stderr"]?.stringValue, "err\n")
        XCTAssertEqual(r.structured?["timed_out"]?.boolValue, false)
        let text = r.content.first.flatMap { if case .text(let t) = $0 { return t } else { return nil } } ?? ""
        XCTAssertTrue(text.hasSuffix("[exit 3]"), text)
    }

    func testCwdAndEnv() async throws {
        let r = try await tool.call(arguments: ["command": "pwd; echo $FOO", "cwd": "/private/tmp", "env": ["FOO": "bar"]])
        XCTAssertEqual(r.structured?["exit_code"]?.intValue, 0)
        XCTAssertEqual(r.structured?["stdout"]?.stringValue, "/private/tmp\nbar\n")
    }

    func testTimeoutKillsChildTree() async throws {
        let start = Date()
        // Child `sleep` is a grandchild; the session kill must take it too.
        let r = try await tool.call(arguments: ["command": "sleep 30 & wait", "timeout_secs": 0.5])
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        XCTAssertEqual(r.structured?["timed_out"]?.boolValue, true)
        XCTAssertTrue(r.isError)
    }

    func testTruncation() async throws {
        let r = try await tool.call(arguments: ["command": "head -c 100000 /dev/zero | tr '\\0' a", "max_output_bytes": 1000])
        XCTAssertEqual(r.structured?["stdout"]?.stringValue?.count, 1000)
        XCTAssertEqual(r.structured?["stdout_truncated"]?.boolValue, true)
    }

    func testMissingCommandIsInvalidParams() async {
        do { _ = try await tool.call(arguments: [:]); XCTFail() }
        catch let e as JSONRPCError { XCTAssertEqual(e.code, JSONRPCError.invalidParams) }
        catch { XCTFail("\(error)") }
    }
}

// MARK: - input

final class InputParsingTests: XCTestCase {
    func testSimpleKey() throws {
        let c = try Input.parseCombo("return")
        XCTAssertEqual(c.code, 0x24); XCTAssertEqual(c.flags, [])
    }

    func testComboCaseInsensitiveWithSpaces() throws {
        let c = try Input.parseCombo("Cmd + Shift + 4")
        XCTAssertEqual(c.code, 0x15)
        XCTAssertTrue(c.flags.contains(.maskCommand)); XCTAssertTrue(c.flags.contains(.maskShift))
        XCTAssertFalse(c.flags.contains(.maskControl))
    }

    func testModifierAliases() throws {
        XCTAssertEqual(try Input.parseCombo("option+left").flags, .maskAlternate)
        XCTAssertEqual(try Input.parseCombo("control+c").flags, .maskControl)
        XCTAssertEqual(try Input.parseCombo("meta+v").flags, .maskCommand)
    }

    func testPlusSpelledOut() throws {
        XCTAssertEqual(try Input.parseCombo("cmd+plus").code, 0x18)
    }

    func testUnknownKeyAndModifier() {
        XCTAssertThrowsError(try Input.parseCombo("cmd+nosuchkey"))
        XCTAssertThrowsError(try Input.parseCombo("hyper+a"))
        XCTAssertThrowsError(try Input.parseCombo(""))
        // Modifier in key position is an error, not a no-op press.
        XCTAssertThrowsError(try Input.parseCombo("cmd"))
    }

    func testKeycodeTableCoversAsciiPrintables() {
        for ch in "abcdefghijklmnopqrstuvwxyz0123456789-=[]\\;',./`" {
            XCTAssertNotNil(Input.keycodes[String(ch)], "missing keycode for \(ch)")
        }
    }

    func testMouseRequiresActionAndCoords() async {
        // Without Accessibility these throw the TCC ToolError before validation; only
        // assert on the validation path when trusted (CI over SSH is not).
        guard AXIsProcessTrusted() else { return }
        let m = MouseTool()
        do { _ = try await m.call(arguments: ["action": "click"]); XCTFail() }
        catch let e as JSONRPCError { XCTAssertEqual(e.code, JSONRPCError.invalidParams) } catch { XCTFail("\(error)") }
        do { _ = try await m.call(arguments: ["action": "scroll"]); XCTFail() }
        catch let e as JSONRPCError { XCTAssertEqual(e.code, JSONRPCError.invalidParams) } catch { XCTFail("\(error)") }
    }
}

final class OsascriptToolTests: XCTestCase {
    func testAppleScriptResult() async throws {
        let r = try await OsascriptTool().call(arguments: ["script": "return 6 * 7"])
        XCTAssertFalse(r.isError)
        XCTAssertEqual(r.structured?["result"]?.stringValue, "42")
    }

    func testJavaScriptResult() async throws {
        let r = try await OsascriptTool().call(arguments: ["script": "'x'.repeat(3)", "language": "javascript"])
        XCTAssertEqual(r.structured?["result"]?.stringValue, "xxx")
    }

    func testSyntaxErrorIsErrorResult() async throws {
        let r = try await OsascriptTool().call(arguments: ["script": "tell application"])
        XCTAssertTrue(r.isError)
        XCTAssertNotEqual(r.structured?["exit_code"]?.intValue, 0)
    }

    func testTimeout() async throws {
        let r = try await OsascriptTool().call(arguments: ["script": "delay 30", "timeout_secs": 1])
        XCTAssertTrue(r.isError)
        XCTAssertEqual(r.structured?["timed_out"]?.boolValue, true)
    }
}
