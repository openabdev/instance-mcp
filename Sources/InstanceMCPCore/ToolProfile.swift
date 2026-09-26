import Foundation

/// Which tools a connection may see and call. Chosen by *this* side — the Mac is
/// the MCP server, so scoping is a per-connection tool list here, never MCP
/// parsing in a proxy (instance-mcp `docs/adr/reverse-attach.md`).
///
/// `owner` is the logged-in human's own CLI: everything. `sandbox` is an agent in
/// an `openab-pty` session that a human lent this Mac to: the see→act→see loop
/// (screenshot / mouse / key / osascript / sys_info) but **no `exec*`**, because
/// `exec` is a full shell as the desktop user and the agent already has a shell
/// of its own in the sandbox. Widening later (an approval hop in Connect) is a
/// new profile, not an edit to this one.
public enum ToolProfile: String, Codable, Sendable, CaseIterable {
    case owner
    case sandbox

    /// `nil` means "no filter". Match is on the tool name.
    public func allows(_ toolName: String) -> Bool {
        switch self {
        case .owner: return true
        case .sandbox: return !toolName.hasPrefix("exec")
        }
    }
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
            tools: allTools.filter { profile.allows($0.name) }
        )
    }
}
