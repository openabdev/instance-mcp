import Foundation

/// Which tools a connection may see and call. Chosen by *this* side — the Mac is
/// the MCP server, so scoping is a per-connection tool list here, never MCP
/// parsing in a proxy (instance-mcp `docs/adr/reverse-attach.md`).
///
/// `owner` is the logged-in human's own CLI: everything. `desktop` is an agent in
/// an `openab-pty` session that a human lent this computer to: the see→act→see
/// loop (screenshot / mouse / key / osascript / sys_info) without the `exec*`
/// tools.
///
/// **`desktop` is not a security boundary** (instance-mcp#45). GUI control is a
/// shell: `osascript` runs `do shell script`, `key` can type into a terminal, and
/// `mouse` can open one. Removing `exec*` removes a convenient entry point, not a
/// privilege; lending under `desktop` hands the agent the desktop user's shell for
/// the lease. A profile that is meant to be narrower must be built from tools that
/// cannot reach a shell — `ToolProfileTests` enforces that for every profile that
/// does not declare itself `isShellEquivalent`.
///
/// Wire and persisted value was `sandbox`; it is still accepted and means `desktop`.
public enum ToolProfile: String, Codable, Sendable, CaseIterable {
    case owner
    case desktop

    /// Accepts the pre-rename `sandbox` so existing clients and stored grants work.
    public init?(rawValue: String) {
        switch rawValue {
        case "owner": self = .owner
        case "desktop", "sandbox": self = .desktop
        default: return nil
        }
    }

    public var rawValue: String {
        switch self {
        case .owner: return "owner"
        case .desktop: return "desktop"
        }
    }

    /// Whether this profile grants (directly or through GUI control) the desktop
    /// user's shell. True for both profiles today; a future `observe` / `browser`
    /// profile must be false and is tested to contain no shell-capable tool.
    public var isShellEquivalent: Bool {
        switch self {
        case .owner, .desktop: return true
        }
    }

    /// Local tools that reach a shell as the desktop user, directly or by driving
    /// the GUI. Any profile with `isShellEquivalent == false` must allow none.
    public static let shellCapableTools: Set<String> = ["osascript", "key", "mouse"]

    /// Match is on the tool name.
    public func allows(_ toolName: String) -> Bool {
        switch self {
        case .owner: return true
        case .desktop:
            if toolName.hasPrefix("exec") { return false }
            if toolName.hasPrefix("browser_") { return Self.desktopBrowserTools.contains(toolName) }
            return true
        }
    }

    /// Playwright MCP tools a lent `desktop` grant may use: navigate, read, interact.
    /// Not: arbitrary JavaScript (`browser_evaluate`, `browser_run_code_unsafe`), the
    /// filesystem (upload / PDF), raw network inspection, dialogs, media emulation,
    /// closing the browser. Anything Playwright adds later is denied until listed here.
    /// The browser still uses this computer's persistent profile and network.
    public static let desktopBrowserTools: Set<String> = [
        "browser_navigate", "browser_navigate_back", "browser_snapshot", "browser_find",
        "browser_click", "browser_type", "browser_fill_form", "browser_press_key", "browser_hover",
        "browser_select_option", "browser_wait_for", "browser_tabs", "browser_take_screenshot",
        "browser_console_messages", "browser_resize",
    ]
}

extension MCPServer {
    /// The same server with its tool list narrowed to `profile`. `tools/list`
    /// omits the rest and `tools/call` on an omitted tool is an *unknown tool*
    /// error, indistinguishable from a tool that never existed — the agent is not
    /// told there is something it is not allowed to have.
    public func scoped(to profile: ToolProfile, instructions: String? = nil) -> MCPServer {
        MCPServer(
            name: serverName,
            version: serverVersion,
            instructions: instructions ?? self.instructions,
            tools: allTools.filter { profile.allows($0.name) },
            upstreams: upstreams,
            upstreamFilter: profile
        )
    }
}
