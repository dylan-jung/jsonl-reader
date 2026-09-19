import AppKit

/// One parsed JSON node. Root records are represented by NSNumber(line) in the outline, not Node.
public final class Node {
    public let name: String
    public let value: Any
    public let path: String
    private var _children: [Node]?

    public init(name: String, value: Any, path: String) { self.name = name; self.value = value; self.path = path }

    public var isContainer: Bool { value is [String: Any] || value is [Any] }

    // ponytail: JSONSerialization drops key order, so keys are sorted. Hand-written parser if original order matters.
    public var children: [Node] {
        if let c = _children { return c }
        let c: [Node]
        if let d = value as? [String: Any] {
            c = d.keys.sorted().map { Node(name: $0, value: d[$0]!, path: path + Self.keyPath($0)) }
        } else if let a = value as? [Any] {
            c = a.enumerated().map { Node(name: "[\($0.offset)]", value: $0.element, path: path + "[\($0.offset)]") }
        } else { c = [] }
        _children = c
        return c
    }

    public static func keyPath(_ k: String) -> String {
        k.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) && !k.isEmpty ? ".\(k)" : "[\"\(k)\"]"
    }

    public static func isBool(_ v: Any) -> Bool { v is NSNumber && CFGetTypeID(v as CFTypeRef) == CFBooleanGetTypeID() }

    /// Short single-line rendering for the Value column.
    public static func summary(_ v: Any) -> (String, NSColor) {
        switch v {
        case let d as [String: Any]: return ("{ \(d.count) keys }", .secondaryLabelColor)
        case let a as [Any]:         return ("[ \(a.count) items ]", .secondaryLabelColor)
        case let s as String:        return ("\"" + s.prefix(500).replacingOccurrences(of: "\n", with: "⏎") + "\"", .systemGreen)
        case is NSNull:              return ("null", .systemGray)
        case let n as NSNumber:      return isBool(n) ? (n.boolValue ? "true" : "false", .systemPurple) : (n.stringValue, .systemBlue)
        default:                     return ("\(v)", .labelColor)
        }
    }

    /// One-line record preview: every key with a short value, nested containers collapsed. Colored by type.
    public static func inline(_ v: Any, limit: Int = 400) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let para = NSMutableParagraphStyle(); para.lineBreakMode = .byTruncatingTail
        func add(_ s: String, _ c: NSColor) { out.append(NSAttributedString(string: s, attributes: [.foregroundColor: c, .paragraphStyle: para])) }
        func leaf(_ v: Any) {
            switch v {
            case let d as [String: Any]: add("{…\(d.count)}", .secondaryLabelColor)
            case let a as [Any]:         add("[…\(a.count)]", .secondaryLabelColor)
            case let s as String:        add("\"" + s.prefix(80).replacingOccurrences(of: "\n", with: "⏎") + (s.count > 80 ? "…\"" : "\""), .systemGreen)
            default:                     let (t, c) = summary(v); add(t, c)
            }
        }
        switch v {
        case let d as [String: Any]:
            add("{ ", .secondaryLabelColor)
            for (i, k) in d.keys.sorted().enumerated() {
                if i > 0 { add(", ", .secondaryLabelColor) }
                add(k + ": ", .labelColor); leaf(d[k]!)
                if out.length > limit { add(", …", .secondaryLabelColor); break }
            }
            add(" }", .secondaryLabelColor)
        case let a as [Any]:
            add("[ ", .secondaryLabelColor)
            for (i, e) in a.prefix(20).enumerated() { if i > 0 { add(", ", .secondaryLabelColor) }; leaf(e) }
            if a.count > 20 { add(", …", .secondaryLabelColor) }
            add(" ]", .secondaryLabelColor)
        default: leaf(v)
        }
        return out
    }
}
