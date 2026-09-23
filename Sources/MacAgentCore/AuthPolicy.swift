import Foundation

/// Who may call. Evaluated per request from headers `tailscale serve` injects
/// (`Tailscale-User-Login`) plus an optional shared bearer token.
///
/// Both checks that are configured must pass. With neither configured the server
/// refuses to start — see `validate()` — because a loopback listener behind
/// `tailscale serve` is reachable by every node on the tailnet.
public struct AuthPolicy: Sendable, Equatable {
    /// Lowercased logins, e.g. `you@example.com`. Empty ⇒ identity not checked.
    public var allowedLogins: Set<String>
    /// Constant-time compared. nil ⇒ token not checked.
    public var bearerToken: String?
    /// Requests from loopback *without* Tailscale headers (local debugging) are
    /// allowed only if this is set. Off by default.
    public var allowLocalUnauthenticated: Bool

    public init(allowedLogins: Set<String> = [], bearerToken: String? = nil, allowLocalUnauthenticated: Bool = false) {
        self.allowedLogins = Set(allowedLogins.map { $0.lowercased() })
        self.bearerToken = bearerToken
        self.allowLocalUnauthenticated = allowLocalUnauthenticated
    }

    public enum Decision: Equatable, Sendable {
        case allow(principal: String)
        case deny(reason: String)
    }

    public struct ValidationError: Error, CustomStringConvertible {
        public let description: String
    }

    public func validate() throws {
        if allowedLogins.isEmpty && bearerToken == nil && !allowLocalUnauthenticated {
            throw ValidationError(description:
                "refusing to start with no auth: set --allow-login and/or --token (or --insecure-local for loopback-only debugging)")
        }
    }

    /// `headers` keys are case-insensitive; caller passes them lowercased.
    /// `remoteIsLoopback` is true when the TCP peer is 127.0.0.1/::1 — always the case
    /// behind `tailscale serve`, so it alone proves nothing.
    public func decide(headers: [String: String], remoteIsLoopback: Bool) -> Decision {
        let login = headers["tailscale-user-login"]?.lowercased()
        let viaTailscale = login != nil || headers["x-forwarded-for"] != nil

        // Bearer check first: a wrong token is a deny even for an allowlisted login.
        if let expected = bearerToken {
            guard let auth = headers["authorization"] else {
                return .deny(reason: "missing Authorization header")
            }
            let prefix = "bearer "
            guard auth.lowercased().hasPrefix(prefix) else {
                return .deny(reason: "Authorization must be Bearer")
            }
            let presented = String(auth.dropFirst(prefix.count))
            guard constantTimeEquals(presented, expected) else {
                return .deny(reason: "bad token")
            }
        }

        if !allowedLogins.isEmpty {
            guard let login else {
                if remoteIsLoopback && !viaTailscale && allowLocalUnauthenticated {
                    return .allow(principal: "local")
                }
                return .deny(reason: "no Tailscale identity on request")
            }
            guard allowedLogins.contains(login) else {
                return .deny(reason: "login \(login) not allowed")
            }
            return .allow(principal: login)
        }

        if let login { return .allow(principal: login) }
        if bearerToken != nil { return .allow(principal: "token") }
        if remoteIsLoopback && !viaTailscale && allowLocalUnauthenticated {
            return .allow(principal: "local")
        }
        return .deny(reason: "unauthenticated")
    }

    private func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<x.count { diff |= x[i] ^ y[i] }
        return diff == 0
    }
}
