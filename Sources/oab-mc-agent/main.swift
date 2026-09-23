import CoreGraphics
import Foundation
import MacAgentCore

let version = "0.1.0"

struct Options {
    var host = "127.0.0.1"
    var port: UInt16 = 8795
    var path = "/mcp"
    var allowLogins: Set<String> = []
    var token: String? = nil
    var tokenFile: String? = nil
    var insecureLocal = false
    var quiet = false
}

func usage() -> Never {
    print("""
    oab-mc-agent \(version) — MCP server exposing this Mac (exec / screenshot / sys_info)

    USAGE: oab-mc-agent [--host 127.0.0.1] [--port 8795] [--path /mcp]
                        [--allow-login <email>]... [--token <str> | --token-file <path>]
                        [--insecure-local] [--quiet]

    Auth (at least one required unless --insecure-local):
      --allow-login   Tailscale login (from `tailscale serve`'s Tailscale-User-Login header). Repeatable.
      --token         Shared bearer token; clients send `Authorization: Bearer <token>`.
      --token-file    Read the token from a file (trailing newline stripped).
      --insecure-local  Allow unauthenticated requests that arrive on loopback *without*
                        Tailscale headers. For local debugging only.

    Run it as a LaunchAgent in the logged-in user's GUI session (gui/<uid>), not a
    LaunchDaemon — screenshot and input tools need the Aqua session and TCC grants.
    """)
    exit(64)
}

var opts = Options()
var args = Array(CommandLine.arguments.dropFirst())
func next(_ flag: String) -> String {
    guard !args.isEmpty else { fputs("missing value for \(flag)\n", stderr); usage() }
    return args.removeFirst()
}
while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "--host": opts.host = next(a)
    case "--port":
        guard let p = UInt16(next(a)) else { fputs("bad port\n", stderr); usage() }
        opts.port = p
    case "--path": opts.path = next(a)
    case "--allow-login": opts.allowLogins.insert(next(a))
    case "--token": opts.token = next(a)
    case "--token-file": opts.tokenFile = next(a)
    case "--insecure-local": opts.insecureLocal = true
    case "--quiet": opts.quiet = true
    case "--version": print(version); exit(0)
    case "-h", "--help": usage()
    default: fputs("unknown flag \(a)\n", stderr); usage()
    }
}

if let f = opts.tokenFile {
    guard let s = try? String(contentsOfFile: (f as NSString).expandingTildeInPath, encoding: .utf8) else {
        fputs("cannot read --token-file \(f)\n", stderr); exit(66)
    }
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !t.isEmpty else { fputs("--token-file is empty\n", stderr); exit(66) }
    opts.token = t
}

let auth = AuthPolicy(allowedLogins: opts.allowLogins, bearerToken: opts.token, allowLocalUnauthenticated: opts.insecureLocal)
do { try auth.validate() } catch { fputs("\(error)\n", stderr); exit(64) }

let fmt = ISO8601DateFormatter()
let log: @Sendable (String) -> Void = { msg in
    if opts.quiet { return }
    FileHandle.standardError.write(Data("\(fmt.string(from: Date())) \(msg)\n".utf8))
}

let server = MCPServer(
    name: "oab-mc-agent",
    version: version,
    instructions: """
        This server is a Mac (\(Host.current().localizedName ?? "unknown")) running in its logged-in \
        desktop session. `exec` runs shell commands as the desktop user; `screenshot` returns what is \
        on screen; call `sys_info` first to learn displays and which permissions are granted.
        """,
    tools: [SysInfoTool(agentVersion: version), ExecTool(), ScreenshotTool()]
)
let endpoint = MCPHTTPEndpoint(path: opts.path, server: server, auth: auth, log: log)

// Must be a global: a `let` inside `do {}` is released after the block and the
// listener's [weak self] handlers silently stop accepting connections.
let http: LoopbackHTTPServer
do {
    http = try LoopbackHTTPServer(host: opts.host, port: opts.port, endpoint: endpoint, log: log)
} catch {
    fputs("failed to start listener: \(error)\n", stderr); exit(2)
}
log("oab-mc-agent \(version) starting on http://\(opts.host):\(opts.port)\(opts.path) " +
    "auth=[logins:\(opts.allowLogins.sorted().joined(separator: ",")) token:\(opts.token != nil) insecure-local:\(opts.insecureLocal)] " +
    "screen_recording=\(CGPreflightScreenCaptureAccess())")
http.start()

signal(SIGPIPE, SIG_IGN)
let stop = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
signal(SIGTERM, SIG_IGN)
stop.setEventHandler { log("SIGTERM, exiting"); exit(0) }
stop.resume()

RunLoop.main.run()
