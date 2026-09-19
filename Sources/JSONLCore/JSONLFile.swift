import Foundation

/// Memory-mapped JSONL file. Only newline offsets are held in memory.
public final class JSONLFile: @unchecked Sendable {
    public let url: URL
    public let data: Data          // .mappedIfSafe → pages load on demand
    public private(set) var lineStarts: [Int] = []   // byte offset where each line begins
    public private(set) var badLines: Set<Int> = []  // line indices that failed the cheap check

    public init(url: URL) throws {
        self.url = url
        let mapped = try Data(contentsOf: url, options: .mappedIfSafe)
        self.data = url.pathExtension.lowercased() == "json" ? Self.jsonToLines(mapped) : mapped
    }

    // ponytail: .json is fully parsed in memory (not mmap'd). Top-level array → one record per line,
    // anything else → one record. Fine for typical .json sizes; stream-parse if multi-GB .json shows up.
    private static func jsonToLines(_ d: Data) -> Data {
        guard let obj = try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed]) else { return d }
        let items: [Any] = (obj as? [Any]) ?? [obj]
        var out = Data()
        for item in items {
            if let line = try? JSONSerialization.data(withJSONObject: item, options: [.fragmentsAllowed, .withoutEscapingSlashes]) {
                out.append(line); out.append(0x0A)
            }
        }
        return out
    }

    public var lineCount: Int { lineStarts.count }

    /// Scan for '\n' with memchr. ~1GB/s. Called once on a background thread. `maxLines` stops early (Quick Look).
    public func index(maxLines: Int = .max) {
        var starts: [Int] = [0]
        var bad: Set<Int> = []
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            guard let base = buf.baseAddress, buf.count > 0 else { starts = []; return }
            var pos = 0
            let n = buf.count
            while pos < n {
                let rest = n - pos
                guard let hit = memchr(base + pos, 0x0A, rest) else {
                    if !Self.looksLikeJSON(base + pos, rest) { bad.insert(starts.count - 1) }
                    break
                }
                let end = UnsafeRawPointer(hit) - base
                if !Self.looksLikeJSON(base + pos, end - pos) { bad.insert(starts.count - 1) }
                pos = end + 1
                if starts.count >= maxLines { break }
                if pos < n { starts.append(pos) }
            }
        }
        lineStarts = starts
        badLines = bad
    }

    // ponytail: cheap check = trimmed line starts with { or [ and ends with } or ].
    // Full JSONSerialization only runs on the selected line. Upgrade to full validation if false negatives bite.
    private static func looksLikeJSON(_ p: UnsafeRawPointer, _ len: Int) -> Bool {
        var s = 0, e = len - 1
        let b = p.assumingMemoryBound(to: UInt8.self)
        while s <= e, b[s] == 0x20 || b[s] == 0x09 || b[s] == 0x0D { s += 1 }
        while e >= s, b[e] == 0x20 || b[e] == 0x09 || b[e] == 0x0D { e -= 1 }
        if s > e { return true }  // blank line: tolerate
        return (b[s] == 0x7B && b[e] == 0x7D) || (b[s] == 0x5B && b[e] == 0x5D)
    }

    public func range(of line: Int) -> Range<Int> {
        let start = lineStarts[line]
        var end = line + 1 < lineStarts.count ? lineStarts[line + 1] - 1 : data.count
        if end > start, data[end - 1] == 0x0A { end -= 1 }   // last line of a newline-terminated file
        if end > start, data[end - 1] == 0x0D { end -= 1 }
        return start..<end
    }

    public func raw(_ line: Int) -> String {
        String(decoding: data[range(of: line)], as: UTF8.self)
    }

    public func preview(_ line: Int, max: Int = 200) -> String {
        let r = range(of: line)
        let cut = r.lowerBound..<min(r.upperBound, r.lowerBound + max)
        return String(decoding: data[cut], as: UTF8.self)
    }

    public func preview(line item: Any, max: Int) -> String { preview((item as! NSNumber).intValue, max: max) }

    public func pretty(_ line: Int) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data[range(of: line)], options: [.fragmentsAllowed]),
              let out = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
        else { return nil }
        return String(decoding: out, as: UTF8.self)
    }

    /// Parse one line fully. nil if invalid JSON.
    public func parsed(_ line: Int) -> Any? {
        try? JSONSerialization.jsonObject(with: data[range(of: line)], options: [.fragmentsAllowed])
    }

    /// Returns matching line indices. Plain: byte scan, case-insensitive = ASCII fold.
    /// ponytail: regex decodes every line to String and runs NSRegularExpression — ~10x slower than plain. Fine under ~1GB.
    public func search(_ needle: String, caseInsensitive: Bool, regex: Bool = false) throws -> [Int] {
        guard !needle.isEmpty else { return Array(0..<lineCount) }
        if regex {
            let re = try NSRegularExpression(pattern: needle, options: caseInsensitive ? [.caseInsensitive] : [])
            return (0..<lineCount).filter { i in
                let s = raw(i)
                return re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
            }
        }
        let n = Array(caseInsensitive ? needle.lowercased().utf8 : needle.utf8)
        var hits: [Int] = []
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            let b = buf.bindMemory(to: UInt8.self)
            for i in 0..<lineCount {
                let r = range(of: i)
                if r.count < n.count { continue }
                var j = r.lowerBound
                let last = r.upperBound - n.count
                outer: while j <= last {
                    for k in 0..<n.count {
                        var c = b[j + k]
                        if caseInsensitive, c >= 0x41, c <= 0x5A { c |= 0x20 }
                        if c != n[k] { j += 1; continue outer }
                    }
                    hits.append(i); break
                }
            }
        }
        return hits
    }
}
