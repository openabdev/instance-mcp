import Foundation
import CoreGraphics

public struct MouseTool: Tool {
    public let name = "mouse"
    public let description = """
        Mouse input on this Mac via CGEvent. Coordinates are display POINTS relative to the \
        top-left of `display` — the same space as `screenshot` (at the default scale 1.0, image pixel \
        == point; with a `region` crop add the region origin; at other scales divide pixels by scale). Actions: `move`, `click` (left), \
        `double_click`, `right_click`, `drag` (from x,y to to_x,to_y), `scroll` (dx/dy in lines; \
        positive dy scrolls content up — i.e. wheel toward you is negative). Requires Accessibility.
        """
    public let inputSchema: JSONValue = [
        "type": "object",
        "properties": [
            "action": ["type": "string", "enum": ["move", "click", "double_click", "right_click", "drag", "scroll"]],
            "x": ["type": "number"], "y": ["type": "number"],
            "to_x": ["type": "number", "description": "drag destination"], "to_y": ["type": "number"],
            "dx": ["type": "integer", "description": "scroll: horizontal lines"], "dy": ["type": "integer", "description": "scroll: vertical lines"],
            "display": ["type": "integer", "default": 0],
            "modifiers": ["type": "array", "items": ["type": "string"], "description": "held during click, e.g. [\"cmd\"], [\"shift\"]"],
        ],
        "required": ["action"],
    ]

    public init() {}

    public func call(arguments a: JSONValue) async throws -> ToolResult {
        try Input.requireAccessibility()
        guard let action = a["action"]?.stringValue else { throw JSONRPCError.invalidParams("action is required") }
        let display = a["display"]?.intValue ?? 0
        var flags = CGEventFlags()
        for m in a["modifiers"]?.arrayValue ?? [] {
            guard let s = m.stringValue?.lowercased(), let f = Input.modifiers[s] else { throw ToolError("unknown modifier \(m)") }
            flags.insert(f)
        }

        func point() throws -> CGPoint {
            guard let x = a["x"]?.doubleValue, let y = a["y"]?.doubleValue else {
                throw JSONRPCError.invalidParams("x and y are required for \(action)")
            }
            return try Input.globalPoint(x: x, y: y, display: display)
        }

        switch action {
        case "move":
            let p = try point()
            try Input.post(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left))
            return .text("moved to (\(Int(p.x)), \(Int(p.y)))")

        case "click", "double_click", "right_click":
            let p = try point()
            let right = action == "right_click"
            let down: CGEventType = right ? .rightMouseDown : .leftMouseDown
            let up: CGEventType = right ? .rightMouseUp : .leftMouseUp
            let button: CGMouseButton = right ? .right : .left
            try Input.post(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: button))
            await Input.sleep(ms: 30)
            let clicks: Int64 = action == "double_click" ? 2 : 1
            for i in 1...clicks {
                let d = CGEvent(mouseEventSource: nil, mouseType: down, mouseCursorPosition: p, mouseButton: button)
                let u = CGEvent(mouseEventSource: nil, mouseType: up, mouseCursorPosition: p, mouseButton: button)
                for e in [d, u] { e?.setIntegerValueField(.mouseEventClickState, value: i); e?.flags = flags }
                try Input.post(d); await Input.sleep(ms: 20); try Input.post(u)
                if i < clicks { await Input.sleep(ms: 60) }
            }
            return .text("\(action) at (\(Int(p.x)), \(Int(p.y)))\(flags.isEmpty ? "" : " with modifiers")")

        case "drag":
            let from = try point()
            guard let tx = a["to_x"]?.doubleValue, let ty = a["to_y"]?.doubleValue else {
                throw JSONRPCError.invalidParams("to_x and to_y are required for drag")
            }
            let to = try Input.globalPoint(x: tx, y: ty, display: display)
            try Input.post(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: from, mouseButton: .left))
            await Input.sleep(ms: 30)
            try Input.post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: from, mouseButton: .left))
            let steps = 12
            for i in 1...steps {
                let t = Double(i) / Double(steps)
                let p = CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
                try Input.post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: p, mouseButton: .left))
                await Input.sleep(ms: 15)
            }
            try Input.post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: to, mouseButton: .left))
            return .text("dragged (\(Int(from.x)), \(Int(from.y))) → (\(Int(to.x)), \(Int(to.y)))")

        case "scroll":
            let dx = Int32(a["dx"]?.intValue ?? 0), dy = Int32(a["dy"]?.intValue ?? 0)
            guard dx != 0 || dy != 0 else { throw JSONRPCError.invalidParams("scroll needs dx or dy") }
            if a["x"] != nil {
                let p = try point()
                try Input.post(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left))
                await Input.sleep(ms: 20)
            }
            try Input.post(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0))
            return .text("scrolled dx=\(dx) dy=\(dy)")

        default:
            throw JSONRPCError.invalidParams("unknown action \(action)")
        }
    }
}
