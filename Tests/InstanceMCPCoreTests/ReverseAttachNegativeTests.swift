import Foundation
import Network
import XCTest
@testable import InstanceMCPCore

/// A plain TCP listener that answers every WebSocket upgrade with 401, the way a
/// runtime does when the bearer is wrong. It speaks no WebSocket at all, so the
/// only thing the client can learn is the HTTP status.
final class PlainRefusingRuntime: @unchecked Sendable {
    private let lock = NSLock()
    private var dialCount = 0
    private var seenAuthorization: [String] = []
    private let listener: NWListener
    private let queue = DispatchQueue(label: "plain-refusing-runtime")
    private(set) var port: UInt16 = 0

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        let sem = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { [weak self] st in
            if case .ready = st { self?.port = self?.listener.port?.rawValue ?? 0; sem.signal() }
            if case .failed = st { sem.signal() }
        }
        listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        listener.start(queue: queue)
        sem.wait()
    }

    func stop() { listener.cancel() }

    var dials: Int { lock.lock(); defer { lock.unlock() }; return dialCount }
    var authorizations: [String] { lock.lock(); defer { lock.unlock() }; return seenAuthorization }

    private func accept(_ conn: NWConnection) {
        lock.lock(); dialCount += 1; lock.unlock()
        conn.start(queue: queue)
        readHead(conn, buffer: Data())
    }

    private func readHead(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            var buf = buffer
            if let data { buf.append(data) }
            if let end = buf.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buf[..<end.lowerBound], as: UTF8.self)
                let auth = head.components(separatedBy: "\r\n")
                    .first { $0.lowercased().hasPrefix("authorization:") }
                    .map { String($0.dropFirst("authorization:".count)).trimmingCharacters(in: .whitespaces) }
                self?.record(auth ?? "")
                let reply = "HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                conn.send(content: Data(reply.utf8), completion: .contentProcessed { _ in conn.cancel() })
                return
            }
            if isComplete || error != nil { conn.cancel(); return }
            self?.readHead(conn, buffer: buf)
        }
    }

    private func record(_ authorization: String) {
        lock.lock(); seenAuthorization.append(authorization); lock.unlock()
    }
}

final class ReverseAttachRefusedUpgradeTests: XCTestCase {
    /// The real client dials a runtime that answers 401. It must stop after one
    /// dial, send the bearer it was given, and end with handshakeRejected(401).
    func testWrongBearerIsRefusedOnceAndStops() async throws {
        let runtime = try PlainRefusingRuntime()
        defer { runtime.stop() }
        let config = ReverseAttachClient.Config(
            runtime: URL(string: "ws://127.0.0.1:\(runtime.port)")!,
            session: "s", secret: "right", profile: .owner,
            deadline: Date().addingTimeInterval(10))
        let client = ReverseAttachClient(config: config,
                                         server: MCPServer(name: "t", version: "0", tools: [EchoTool()]))
        await client.start()

        var state = await client.state
        for _ in 0..<200 {
            if case .ended = state { break }
            try await Task.sleep(nanoseconds: 50_000_000)
            state = await client.state
        }
        XCTAssertEqual(state, .ended(.handshakeRejected(401)))
        XCTAssertEqual(runtime.dials, 1, "a refused upgrade must not be retried")
        XCTAssertEqual(runtime.authorizations, ["Bearer right"])
    }
}

final class AttachCredentialSecrecyTests: XCTestCase {
    private func attachReq(_ method: String, _ path: String, body: JSONValue? = nil) -> HTTPRequest {
        let h = ["content-type": "application/json", "tailscale-user-login": "a@b", "x-forwarded-for": "100.1.1.1"]
        let data = body.map { try! JSONCoding.encoder.encode($0) } ?? Data()
        return HTTPRequest(method: method, path: path, query: nil, headers: h, body: data)
    }

    /// The attach secret goes in on POST and must not come back out on any
    /// read route. The grant body is what Connect and Remote display.
    func testGrantBodiesNeverCarryTheAttachSecret() async throws {
        let canary = "CANARY-SECRET-7f3a"
        let mgr = AttachManager(server: fullServer())
        let ep = MCPHTTPEndpoint(server: fullServer(), auth: AuthPolicy(allowedLogins: ["a@b"]), attach: mgr)

        let post = await ep.handle(attachReq("POST", "/attach",
            body: ["runtime": "ws://127.0.0.1:1", "session": "s", "secret": .string(canary)]),
            remoteIsLoopback: true)
        XCTAssertTrue((200..<300).contains(post.status), "POST /attach: \(post.status)")
        let id = try XCTUnwrap(decodeJSON(post.body)["id"]?.stringValue)

        let list = await ep.handle(attachReq("GET", "/attach"), remoteIsLoopback: true)
        let one = await ep.handle(attachReq("GET", "/attach/\(id)"), remoteIsLoopback: true)
        XCTAssertEqual(list.status, 200, "GET /attach: \(list.status)")
        XCTAssertEqual(one.status, 200, "GET /attach/<id>: \(one.status)")
        XCTAssertTrue(String(decoding: list.body, as: UTF8.self).contains(id), "grant id missing from GET /attach")
        for r in [post, list, one] {
            XCTAssertFalse(String(decoding: r.body, as: UTF8.self).contains(canary),
                           "secret leaked in \(r.status) body")
        }

        let del = await ep.handle(attachReq("DELETE", "/attach/\(id)"), remoteIsLoopback: true)
        XCTAssertTrue((200..<300).contains(del.status), "DELETE /attach/<id>: \(del.status)")
    }
}
