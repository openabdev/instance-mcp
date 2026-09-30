import Foundation
import XCTest
@testable import InstanceMCPCore

/// instance-mcp#45: a tool profile is only a security boundary if it cannot reach
/// the desktop user's shell. GUI control is a shell — `osascript` runs
/// `do shell script`, `key` types into a terminal, `mouse` opens one — so a profile
/// that hides `exec*` but keeps those is not narrower in privilege, only in
/// convenience. These tests make that impossible to claim by accident.
final class ProfileBoundaryTests: XCTestCase {
    /// Every local tool this daemon ships, by name, straight from the source so a
    /// new tool is covered without anyone remembering to list it here.
    private func shippedLocalToolNames() throws -> Set<String> {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/InstanceMCPCore/Tools")
        var names = Set<String>()
        for file in try FileManager.default.contentsOfDirectory(atPath: dir.path) where file.hasSuffix(".swift") {
            let text = try String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8)
            let regex = try NSRegularExpression(pattern: #"let name = "([a-z_]+)""#)
            for m in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let r = Range(m.range(at: 1), in: text) { names.insert(String(text[r])) }
            }
        }
        return names
    }

    func testTheToolScanSeesTheShellCapableTools() throws {
        let shipped = try shippedLocalToolNames()
        for tool in ["exec", "osascript", "key", "mouse", "screenshot", "sys_info"] {
            XCTAssertTrue(shipped.contains(tool), "tool scan missed \(tool); shipped: \(shipped.sorted())")
        }
    }

    /// The adversary check: a profile that does not declare itself shell-equivalent
    /// must allow no tool that reaches a shell. Today no such profile exists and
    /// `desktop` must say so; a future `observe` / `browser` profile is held to it.
    func testNoProfileClaimsToBeNarrowerThanItIs() throws {
        let shellReaching = try shippedLocalToolNames().filter {
            $0.hasPrefix("exec") || ToolProfile.shellCapableTools.contains($0)
        }
        XCTAssertFalse(shellReaching.isEmpty)
        for profile in ToolProfile.allCases {
            let reachable = shellReaching.filter(profile.allows)
            if !profile.isShellEquivalent {
                XCTAssertTrue(reachable.isEmpty,
                              "\(profile.rawValue) claims no shell but allows \(reachable.sorted())")
            } else {
                XCTAssertFalse(reachable.isEmpty, "\(profile.rawValue) is marked shell-equivalent; keep it honest")
            }
        }
    }

    func testDesktopIsDeclaredShellEquivalent() {
        XCTAssertTrue(ToolProfile.desktop.isShellEquivalent)
        for tool in ["osascript", "key", "mouse"] {
            XCTAssertTrue(ToolProfile.desktop.allows(tool), "\(tool) is part of desktop control")
        }
        XCTAssertFalse(ToolProfile.desktop.allows("exec"))
    }

    /// `observe` is the one real boundary today: look, never act.
    func testObserveCanOnlyLook() throws {
        XCTAssertFalse(ToolProfile.observe.isShellEquivalent)
        let shipped = try shippedLocalToolNames()
        XCTAssertEqual(Set(shipped.filter(ToolProfile.observe.allows)), ["sys_info", "screenshot"])
        for tool in ["browser_navigate", "browser_snapshot", "browser_take_screenshot", "browser_something_new", "exec", "osascript"] {
            XCTAssertFalse(ToolProfile.observe.allows(tool), "\(tool) is an action, or unknown")
        }
    }

    func testNoAllowedBrowserToolRunsArbitraryCode() {
        for tool in ["browser_evaluate", "browser_run_code_unsafe"] {
            XCTAssertFalse(ToolProfile.desktopBrowserTools.contains(tool))
            XCTAssertFalse(ToolProfile.desktop.allows(tool), tool)
        }
    }

    /// `sandbox` promised a boundary that does not exist; it is refused, not aliased.
    func testTheOldSandboxNameIsRefused() throws {
        XCTAssertNil(ToolProfile(rawValue: "sandbox"))
        XCTAssertEqual(ToolProfile(rawValue: "desktop"), .desktop)
        XCTAssertEqual(ToolProfile(rawValue: "owner"), .owner)
        XCTAssertEqual(ToolProfile(rawValue: "observe"), .observe)
        XCTAssertNil(ToolProfile(rawValue: "browser"), "unknown profiles must not widen to anything")
        XCTAssertNil(ToolProfile(rawValue: "Observe"))
        XCTAssertEqual(ToolProfile.desktop.rawValue, "desktop")
        let decoded = try JSONDecoder().decode([ToolProfile].self, from: Data(#"["observe","desktop","owner"]"#.utf8))
        XCTAssertEqual(decoded, [.observe, .desktop, .owner])
        XCTAssertThrowsError(try JSONDecoder().decode([ToolProfile].self, from: Data(#"["sandbox"]"#.utf8)))
        XCTAssertEqual(String(decoding: try JSONEncoder().encode(ToolProfile.desktop), as: UTF8.self), #""desktop""#)
    }
}
