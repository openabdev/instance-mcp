import Foundation
import CoreGraphics

public struct KeyTool: Tool {
    public let name = "key"
    public let description = """
        Keyboard input on this Mac via CGEvent. `type`: send `text` as typed unicode into the \
        focused app (layout-independent, any script; newlines become Return). `press`: one or more \
        key combos in `keys`, e.g. ["cmd+l", "cmd+a"], ["return"], ["ctrl+c"]; modifiers cmd/ctrl/alt/shift/fn, \
        keys are letters, digits, punctuation, or return tab space delete escape left right up down \
        home end pageup pagedown f1–f12. Requires Accessibility.
        """
    public let inputSchema: JSONValue = [
        "type": "object",
        "properties": [
            "action": ["type": "string", "enum": ["type", "press"]],
            "text": ["type": "string", "description": "for type"],
            "keys": ["type": "array", "items": ["type": "string"], "description": "for press; combos executed in order"],
            "delay_ms": ["type": "integer", "description": "pause between keystrokes/combos. Default 10 (type) / 50 (press)."],
        ],
        "required": ["action"],
    ]

    public init() {}

    public func call(arguments a: JSONValue) async throws -> ToolResult {
        try Input.requireAccessibility()
        guard let action = a["action"]?.stringValue else { throw JSONRPCError.invalidParams("action is required") }
        switch action {
        case "type":
            guard let text = a["text"]?.stringValue, !text.isEmpty else { throw JSONRPCError.invalidParams("text is required") }
            guard text.utf16.count <= 20_000 else { throw ToolError("text too long (max 20000 UTF-16 units)") }
            let delay = a["delay_ms"]?.intValue ?? 10
            var count = 0
            for ch in text {
                if ch == "\n" || ch == "\r" {
                    try Self.press(.init(code: Input.keycodes["return"]!, flags: []))
                } else {
                    try Self.typeUnicode(String(ch))
                }
                count += 1
                if delay > 0 { await Input.sleep(ms: delay) }
            }
            return .text("typed \(count) character(s)")

        case "press":
            guard let keys = a["keys"]?.arrayValue, !keys.isEmpty else { throw JSONRPCError.invalidParams("keys is required") }
            let delay = a["delay_ms"]?.intValue ?? 50
            var done: [String] = []
            for k in keys {
                guard let s = k.stringValue else { throw JSONRPCError.invalidParams("keys must be strings") }
                try Self.press(try Input.parseCombo(s))
                done.append(s)
                await Input.sleep(ms: delay)
            }
            return .text("pressed " + done.joined(separator: ", "))

        default:
            throw JSONRPCError.invalidParams("unknown action \(action)")
        }
    }

    static func press(_ c: Input.KeyCombo) throws {
        let down = CGEvent(keyboardEventSource: nil, virtualKey: c.code, keyDown: true)
        let up = CGEvent(keyboardEventSource: nil, virtualKey: c.code, keyDown: false)
        down?.flags = c.flags; up?.flags = c.flags
        try Input.post(down)
        usleep(15_000)
        try Input.post(up)
    }

    /// Unicode typing: keycode 0 with an explicit unicode string; the target app receives the
    /// characters regardless of keyboard layout. One grapheme cluster per event pair.
    static func typeUnicode(_ s: String) throws {
        var units = Array(s.utf16)
        let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)
        let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
        down?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
        up?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
        try Input.post(down)
        usleep(5_000)
        try Input.post(up)
    }
}
