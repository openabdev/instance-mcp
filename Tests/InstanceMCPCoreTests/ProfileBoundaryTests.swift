import Foundation
import XCTest
@testable import InstanceMCPCore

/// instance-mcp#45: a tool profile is only a security boundary if it cannot reach
/// the desktop user's shell. GUI control is a shell — `osascript` runs
/// `do shell script`, `key` types into a terminal, `mouse` opens one — so a profile
/// that hides `exec*` but keeps those is not narrower in privilege, only in
/// convenience. These tests make that impossible to claim by accident.
final class ProfileBoundaryTests: XCTestCase {
    /// The tools the daemon actually serves (the same list `main.swift` uses).
    private var served: [String] { ToolCatalog.local(agentVersion: "test").map(\.name) }

    /// Tool names declared in the Tools sources, as a cross-check that nothing is
    /// served from outside the catalog.
    private func declaredToolNames() throws -> Set<String> {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/InstanceMCPCore/Tools")
        var names = Set<String>()
        let regex = try NSRegularExpression(pattern: #"\bname\s*=\s*"([a-z_]+)""#)
        for file in try FileManager.default.contentsOfDirectory(atPath: dir.path) where file.hasSuffix(".swift") {
            let text = try String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8)
            for m in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let r = Range(m.range(at: 1), in: text) { names.insert(String(text[r])) }
            }
        }
        return names
    }

    /// The fix for "the dangerous list is hand-maintained": classification is
    /// exhaustive. A new tool that nobody classified fails here instead of being
    /// silently treated as safe.
    func testEveryServedToolIsClassified() {
        let unclassified = served.filter { ToolProfile.localToolClass[$0] == nil }
        XCTAssertTrue(unclassified.isEmpty,
                      "classify in ToolProfile.localToolClass (observe / act / shell): \(unclassified.sorted())")
        let stale = Set(ToolProfile.localToolClass.keys).subtracting(served)
        XCTAssertTrue(stale.isEmpty, "classified but not served: \(stale.sorted())")
        XCTAssertEqual(served.count, Set(served).count, "duplicate tool names")
    }

    func testEveryDeclaredToolIsInTheCatalog() throws {
        let declared = try declaredToolNames()
        XCTAssertTrue(declared.isSuperset(of: ["exec", "osascript", "key", "mouse", "screenshot", "sys_info"]),
                      "source scan broke: \(declared.sorted())")
        let outside = declared.subtracting(served)
        XCTAssertTrue(outside.isEmpty, "declared but not in ToolCatalog.local: \(outside.sorted())")
    }

    /// The adversary check: a profile that does not declare itself shell-equivalent
    /// must allow no tool classified `.shell`; one that does must actually allow one.
    func testNoProfileClaimsToBeNarrowerThanItIs() {
        let shell = served.filter { ToolProfile.localToolClass[$0] == .shell }
        XCTAssertFalse(shell.isEmpty)
        for profile in ToolProfile.allCases {
            let reachable = shell.filter(profile.allows)
            if !profile.isShellEquivalent {
                XCTAssertTrue(reachable.isEmpty,
                              "\(profile.rawValue) claims no shell but allows \(reachable.sorted())")
            } else {
                XCTAssertFalse(reachable.isEmpty, "\(profile.rawValue) is marked shell-equivalent; keep it honest")
            }
        }
    }

    /// `observe` may only hold tools that change nothing.
    func testObserveAllowsOnlyObserveClassTools() {
        let wrong = served.filter { ToolProfile.observe.allows($0) && ToolProfile.localToolClass[$0] != .observe }
        XCTAssertTrue(wrong.isEmpty, "observe allows tools that act: \(wrong.sorted())")
    }

    func testDesktopIsDeclaredShellEquivalent() {
        XCTAssertTrue(ToolProfile.desktop.isShellEquivalent)
        for tool in ["osascript", "key", "mouse"] {
            XCTAssertTrue(ToolProfile.desktop.allows(tool), "\(tool) is part of desktop control")
        }
        XCTAssertFalse(ToolProfile.desktop.allows("exec"))
    }

    /// `observe` is the one real boundary today: look, never act.
    func testObserveCanOnlyLook() {
        XCTAssertFalse(ToolProfile.observe.isShellEquivalent)
        XCTAssertEqual(Set(served.filter(ToolProfile.observe.allows)), ["sys_info", "screenshot"])
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
