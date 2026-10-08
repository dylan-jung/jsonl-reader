import AppKit

/// Pretty-printer over the parsed tree (sorted keys, 2-space indent, same shape as JSONSerialization).
/// rendered=true prints string contents as real characters (newlines, tabs, unicode…) — only `"` and `\` stay escaped.
/// Writes into one buffer (O(size)); stops after ~`limit` UTF-8 bytes and says so (detail pane). Copy passes no limit.
public func prettyJSON(_ v: Any, rendered: Bool, limit: Int = .max) -> String {
    var o = ""
    func w(_ v: Any, _ indent: String) {
        let inner = indent + "  "
        switch v {
        case let d as [String: Any]:
            if d.isEmpty { o += "{}"; return }
            o += "{\n"
            for (i, k) in Node.sortedKeys(d).enumerated() {
                if o.utf8.count > limit { return }
                o += (i > 0 ? ",\n" : "") + inner + quote(k, rendered: false) + " : "
                w(d[k]!, inner)
            }
            o += "\n" + indent + "}"
        case let a as [Any]:
            if a.isEmpty { o += "[]"; return }
            o += "[\n"
            for (i, e) in a.enumerated() {
                if o.utf8.count > limit { return }
                o += (i > 0 ? ",\n" : "") + inner
                w(e, inner)
            }
            o += "\n" + indent + "]"
        case let s as String: o += quote(s, rendered: rendered)
        case is NSNull: o += "null"
        case let n as NSNumber: o += Node.isBool(n) ? (n.boolValue ? "true" : "false") : n.stringValue
        default: o += "\(v)"
        }
    }
    w(v, "")
    return o.utf8.count > limit ? o + "\n\n… truncated after \(ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file)). Copy gets the full text." : o
}

public func quote(_ s: String, rendered: Bool) -> String {
    var o = "\""
    for c in s.unicodeScalars {
        switch c {
        case "\"": o += "\\\""
        case "\\": o += "\\\\"
        case "\n": o += rendered ? "\n" : "\\n"
        case "\t": o += rendered ? "\t" : "\\t"
        case "\r": o += rendered ? "\r" : "\\r"
        case "\u{08}": o += rendered ? "\u{08}" : "\\b"
        case "\u{0C}": o += rendered ? "\u{0C}" : "\\f"
        default: if c.value < 0x20 { o += String(format: "\\u%04x", c.value) } else { o.unicodeScalars.append(c) }
        }
    }
    return o + "\""
}


/// Token ranges + colors for pretty-printed JSON (keys default color, strings green, numbers blue, bools purple, null gray).
/// ponytail: regex over our own pretty-printer output; skipped above 300k chars to stay snappy.
public func jsonTokens(_ s: String) -> [(NSRange, NSColor)] {
    guard s.utf16.count < 300_000 else { return [] }
    let re = try! NSRegularExpression(pattern: #"("(?:[^"\\]|\\.)*")(\s*:)?|(-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)|\b(true|false|null)\b"#)
    let ns = s as NSString
    return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { m in
        if m.range(at: 1).location != NSNotFound {
            return (m.range(at: 1), m.range(at: 2).location != NSNotFound ? NSColor.labelColor : NSColor.systemGreen)
        }
        if m.range(at: 3).location != NSNotFound { return (m.range, NSColor.systemBlue) }
        return (m.range, ns.substring(with: m.range(at: 4)) == "null" ? NSColor.systemGray : NSColor.systemPurple)
    }
}

public func highlightedJSON(_ s: String, font: NSFont) -> NSAttributedString {
    let out = NSMutableAttributedString(string: s, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
    for (r, c) in jsonTokens(s) { out.addAttribute(.foregroundColor, value: c, range: r) }
    return out
}

public func jsonTypeName(_ v: Any) -> String {
    switch v {
    case is NSDictionary: return "object"
    case is NSArray: return "array"
    case is String: return "string"
    case is NSNull: return "null"
    case let n as NSNumber: return Node.isBool(n) ? "bool" : "number"
    default: return "?"
    }
}
