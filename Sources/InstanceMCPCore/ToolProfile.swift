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
/// `observe` is the first profile that *is* a boundary: `sys_info` and
/// `screenshot` only. The agent can see the screen (which still discloses what is
/// on it) but cannot change anything, so it is not shell-equivalent.
///
/// The old name `sandbox` is **not** accepted: it described a boundary that does not
/// exist, and a client still sending it has not been updated to say so to its user.
/// It is refused (400) like any unknown profile, and a grant stored under it is dropped.
/// Full per-profile tool lists: `docs/tool-profiles.md`.
public enum ToolProfile: String, Codable, Sendable, CaseIterable {
    case owner
    case desktop
    case observe

    /// Whether this profile grants (directly or through GUI control) the desktop
    /// user's shell. `observe` is not, and `ProfileBoundaryTests` holds it to that:
    /// it must allow no shell-capable tool.
    public var isShellEquivalent: Bool {
        switch self {
        case .owner, .desktop: return true
        case .observe: return false
        }
    }

    /// Everything `observe` may call. An allowlist, so a new tool — local or
    /// upstream — is denied under `observe` until it is listed here.
    public static let observeTools: Set<String> = ["sys_info", "screenshot"]

    /// What a tool can do, as far as a boundary is concerned.
    public enum ToolClass: String, Sendable, CaseIterable {
        /// Reads only; changes nothing.
        case observe
        /// Changes state, but cannot run code as the desktop user.
        case act
        /// Reaches the desktop user's shell, directly or by driving the GUI.
        case shell
    }

    /// Every local tool, classified. **Exhaustive by test**: a tool in
    /// `ToolCatalog.local` without an entry here fails `ProfileBoundaryTests`,
    /// so a new tool cannot slip past the boundary check by simply not being
    /// listed as dangerous. Classify conservatively: if it can open, type into,
    /// or script anything that runs code, it is `.shell`.
    public static let localToolClass: [String: ToolClass] = [
        "sys_info": .observe,
        "screenshot": .observe,
        "exec_poll": .observe,     // reads a job's state and output; starts nothing
        "exec_list": .observe,
        "exec_cancel": .act,       // signals a job's process group
        "exec": .shell,
        "exec_start": .shell,
        "osascript": .shell,       // `do shell script`, JXA, NSTask
        "key": .shell,             // can type into a terminal
        "mouse": .shell,           // can open one
    ]

    /// Local tools that reach a shell as the desktop user. Any profile with
    /// `isShellEquivalent == false` must allow none.
    public static var shellCapableTools: Set<String> {
        Set(localToolClass.filter { $0.value == .shell }.keys)
    }

    /// Match is on the tool name.
    public func allows(_ toolName: String) -> Bool {
        switch self {
        case .owner: return true
        case .desktop:
            if toolName.hasPrefix("exec") { return false }
            if toolName.hasPrefix("browser_") { return Self.desktopBrowserTools.contains(toolName) }
            return true
        case .observe:
            // Both: on the allowlist *and* classified as observation, so a tool added
            // to the allowlist by mistake is still refused unless it changes nothing.
            return Self.observeTools.contains(toolName) && Self.localToolClass[toolName] == .observe
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
