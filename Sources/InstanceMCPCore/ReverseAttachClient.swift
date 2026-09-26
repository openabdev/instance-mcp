import Foundation

/// The Mac's half of reverse attach: dial an `openab-pty` runtime's
/// `GET /tools/attach/{session}`, then act as the MCP **server** on that socket
/// with a per-grant tool profile. Contract: openab-pty `CLIENT-CONTRACT.md` §9.2.
///
/// The runtime is the MCP client here — it sends `initialize` first, then relays
/// the CLI's `tools/list` / `tools/call` with its own integer ids. We answer each
/// frame with the same id and otherwise treat the socket exactly like an HTTP
/// request/response pair: one frame in, one frame out, no server-initiated
/// messages.
///
/// Retry ownership is ours (the pod cannot reach us). Close codes decide:
///
/// | code | meaning (§9.2) | we |
/// |---|---|---|
/// | 4001 | grant TTL elapsed | stop |
/// | 4002 | replaced by a newer attach | stop |
/// | 4004 | session ended | stop |
/// | 4006 | runtime replaced | redial with backoff while the grant is valid |
/// | 4010 | grant revoked | stop |
/// | 1000 / error | dropped | redial with backoff while the grant is valid |
///
/// A `401` on the handshake means the verifier is gone (expired, revoked, or the
/// pod was replaced): stop and report it, there is nothing to wait for.
public actor ReverseAttachClient {
    public enum Terminal: Equatable, Sendable {
        case grantExpired            // 4001
        case replaced                // 4002
        case sessionEnded            // 4004
        case revoked                 // 4010
        case handshakeRejected(Int)  // HTTP status on upgrade, typically 401
        case cancelled
        case deadline                // our own grant deadline passed while redialling
    }

    public enum State: Equatable, Sendable {
        case idle
        case dialing
        case attached
        case waitingToRedial(seconds: Double)
        case ended(Terminal)
    }

    public struct Config: Sendable {
        /// `ws://` or `wss://` base of the runtime, e.g. `ws://100.111.174.31:8090`.
        public var runtime: URL
        public var session: String
        public var secret: String
        public var profile: ToolProfile
        /// When the grant we hold expires, as we understand it. Redialling stops here.
        public var deadline: Date
        public var initialBackoff: TimeInterval = 1
        public var maxBackoff: TimeInterval = 30

        public init(runtime: URL, session: String, secret: String, profile: ToolProfile, deadline: Date) {
            self.runtime = runtime; self.session = session; self.secret = secret
            self.profile = profile; self.deadline = deadline
        }

        public var attachURL: URL {
            var c = URLComponents(url: runtime, resolvingAgainstBaseURL: false)!
            let base = c.path.hasSuffix("/") ? String(c.path.dropLast()) : c.path
            c.path = base + "/tools/attach/" + session
            return c.url!
        }
    }

    /// Pure function of a close code / handshake outcome → what to do. Kept
    /// separate from the socket so the policy in §9.2 is unit-testable.
    public enum Disposition: Equatable, Sendable {
        case stop(Terminal)
        case redial
    }

    public static func disposition(closeCode: Int) -> Disposition {
        switch closeCode {
        case 4001: return .stop(.grantExpired)
        case 4002: return .stop(.replaced)
        case 4004: return .stop(.sessionEnded)
        case 4010: return .stop(.revoked)
        default:   return .redial            // 1000, 1006, 4006, anything else
        }
    }

    public static func disposition(handshakeStatus: Int) -> Disposition {
        switch handshakeStatus {
        case 200..<300, 101: return .redial // not a rejection; caller should not be here
        case 429, 500..<600: return .redial // throttled or the runtime is unwell; wait
        default:             return .stop(.handshakeRejected(handshakeStatus))
        }
    }

    public private(set) var state: State = .idle
    public let config: Config
    private let server: MCPServer
    private let log: @Sendable (String) -> Void
    private var task: URLSessionWebSocketTask?
    private var runLoopTask: Task<Void, Never>?
    private let onStateChange: @Sendable (State) -> Void
    /// Frames answered on the current socket; surfaced for status.
    public private(set) var callsServed: Int = 0
    public private(set) var attachedSince: Date?

    /// `server` should already be `scoped(to: config.profile)`; this type does
    /// not re-scope so a caller can pass a pre-built, instruction-tailored server.
    public init(config: Config, server: MCPServer,
                onStateChange: @escaping @Sendable (State) -> Void = { _ in },
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.config = config; self.server = server; self.onStateChange = onStateChange; self.log = log
    }

    // MARK: lifecycle

    public func start() {
        guard runLoopTask == nil else { return }
        runLoopTask = Task { [weak self] in await self?.run() }
    }

    public func cancel() {
        runLoopTask?.cancel()
        runLoopTask = nil
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        set(.ended(.cancelled))
    }

    private func set(_ s: State) {
        if case .ended = state { return }   // terminal is sticky
        state = s
        onStateChange(s)
    }

    private func run() async {
        var backoff = config.initialBackoff
        while !Task.isCancelled {
            if Date() >= config.deadline { set(.ended(.deadline)); return }
            set(.dialing)
            let outcome = await dialOnce()
            if Task.isCancelled { return }
            switch outcome {
            case .stop(let t):
                log("attach \(config.session): stopping (\(t))")
                set(.ended(t)); return
            case .redial:
                let remaining = config.deadline.timeIntervalSinceNow
                guard remaining > 0 else { set(.ended(.deadline)); return }
                let wait = min(backoff, remaining)
                set(.waitingToRedial(seconds: wait))
                log("attach \(config.session): redial in \(Int(wait))s")
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                backoff = min(backoff * 2, config.maxBackoff)
            }
        }
    }

    /// One connection lifetime. Returns what to do next.
    private func dialOnce() async -> Disposition {
        var req = URLRequest(url: config.attachURL)
        req.setValue("Bearer \(config.secret)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 15
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let ws = session.webSocketTask(with: req)
        ws.maximumMessageSize = 16 * 1024 * 1024
        task = ws
        ws.resume()

        // The handshake outcome is only observable by receiving. A rejected
        // upgrade surfaces as an error whose task has an HTTPURLResponse.
        var served = 0
        var firstFrame = true
        while true {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await ws.receive()
            } catch {
                if Task.isCancelled { return .stop(.cancelled) }
                if let http = ws.response as? HTTPURLResponse, http.statusCode != 101, firstFrame {
                    log("attach \(config.session): handshake rejected \(http.statusCode)")
                    return Self.disposition(handshakeStatus: http.statusCode)
                }
                let code = ws.closeCode.rawValue
                if code != 0 {
                    log("attach \(config.session): closed \(code) after \(served) calls")
                    finishAttached()
                    return Self.disposition(closeCode: code)
                }
                log("attach \(config.session): socket error \(error.localizedDescription)")
                finishAttached()
                return .redial
            }
            if firstFrame {
                firstFrame = false
                attachedSince = Date()
                set(.attached)
                log("attach \(config.session): attached as \(config.profile.rawValue) to \(config.runtime.host ?? "?")")
            }
            let text: String
            switch message {
            case .string(let s): text = s
            case .data(let d): text = String(decoding: d, as: UTF8.self)
            @unknown default: continue
            }
            if let reply = await answer(text) {
                do { try await ws.send(.string(reply)) } catch {
                    finishAttached()
                    return .redial
                }
                served += 1
                callsServed = served
            }
        }
    }

    private func finishAttached() {
        attachedSince = nil
        task = nil
    }

    /// One inbound frame → one reply (nil for notifications). Exactly the HTTP
    /// endpoint's dispatch, minus sessions and auth: the socket *is* the session,
    /// and the grant *is* the auth. No header on this socket is trusted.
    func answer(_ text: String) async -> String? {
        let rpc: JSONRPCRequest
        switch MCPServer.parse(Data(text.utf8)) {
        case .failure(let e):
            return encode(JSONRPCResponse(id: .null, error: e))
        case .success(let r): rpc = r
        }
        guard let response = await server.handle(rpc) else { return nil }
        if rpc.method == "tools/call" {
            let name = rpc.params?["name"]?.stringValue ?? "?"
            log("sandbox[\(config.session)] tools/call \(name)\(response.error != nil ? " -> rpc error" : "")")
        }
        return encode(response)
    }

    private func encode(_ r: JSONRPCResponse) -> String {
        String(decoding: (try? JSONCoding.encoder.encode(r)) ?? Data("{}".utf8), as: UTF8.self)
    }
}
