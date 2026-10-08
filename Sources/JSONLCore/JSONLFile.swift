import Foundation

/// Memory-mapped JSONL / JSON file. A record is a byte range in the mapping, found by walking bytes (never by parsing);
/// only a sparse offset index lives in RAM.
/// .jsonl/.ndjson: one record per line. .json: top-level array → one per element; top-level object → one record, or one
/// per member when the file is over `splitAbove` (too big to parse whole). A .json that is really JSONL falls back to lines.
public final class JSONLFile: @unchecked Sendable {
    public enum Kind { case lines, array, object, whole }
    /// Records bigger than this are never parsed: JSONSerialization needs ~5–20× the bytes in RAM.
    public static let parseLimit = 256 << 20
    static let entryEvery = 1 << 16       // one (record, offset) index entry per ≥64KB of file
    static let flushEvery = 128 << 20     // publish index progress this often
    static let aheadEvery = 64 << 20      // tell the read-ahead thread where the scan is this often

    public let url: URL
    public let data: Data                 // .mappedIfSafe → pages load on demand

    private struct State { var kind: Kind; var base: Int; var recs: [Int] = []; var offs: [Int] = []; var count = 0; var bad: Set<Int> = [] }
    private var st = State(kind: .lines, base: 0)   // guarded by lock: index() writes on a background thread while the UI reads
    private let lock = NSLock()

    public init(url: URL, splitAbove: Int = parseLimit) throws {
        self.url = url
        data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard url.pathExtension.lowercased() == "json" else { return }
        st = bytes { b, n in
            let top = Self.skipWS(b, n >= 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF ? 3 : 0, n)   // skip UTF-8 BOM
            switch top < n ? b[top] : 0 {
            case 0x5B:                    return State(kind: .array, base: Self.skipWS(b, top + 1, n))
            case 0x7B where n > splitAbove: return State(kind: .object, base: Self.skipWS(b, top + 1, n))
            case 0x7B:                    return State(kind: .whole, base: top)
            default:                      return State(kind: .lines, base: 0)
            }
        }
    }

    public var kind: Kind { lock.withLock { st.kind } }
    public var count: Int { lock.withLock { st.count } }
    public var badCount: Int { lock.withLock { st.bad.count } }
    public func isBad(_ i: Int) -> Bool { lock.withLock { st.bad.contains(i) } }

    /// Walk every record once (background thread). The index keeps one (record, offset) entry per ≥64KB of file, so it is
    /// ~16 bytes per 64KB however many records there are (500GB → ~120MB). Publishes every 128MB so the list fills in while
    /// indexing; `progress(bytesDone)` returning false stops. `maxRecords` stops early (Quick Look).
    public func index(maxRecords: Int = .max, progress: ((Int) -> Bool)? = nil) {
        let (k, base) = lock.withLock { (st.kind, st.base) }
        let ahead = maxRecords == .max ? ReadAhead(url.path, from: base, to: data.count) : nil   // not for a Quick Look sample
        defer { ahead?.stop() }
        let isJSONL: Bool = bytes { b, n in
            var recs: [Int] = [], offs: [Int] = [], bad: Set<Int> = []   // locals, not captures: keeps the loop at memchr speed
            var i = 0, lastEnd = base, nextEntry = 0, nextFlush = Self.flushEvery, nextAhead = 0
            let empty = (k == .array || k == .object) && base < n && (b[base] == 0x5D || b[base] == 0x7D)
            var s: Int? = base < n && !empty ? base : nil
            while let cur = s, i < maxRecords {
                if cur >= nextAhead { ahead?.at(cur); nextAhead = cur + Self.aheadEvery }
                if cur >= nextEntry { recs.append(i); offs.append(cur); nextEntry = cur + Self.entryEvery }
                let (e, nx) = Self.step(k, b, cur, n)
                if k == .lines, !Self.looksLikeJSON(b + cur, e - cur) { bad.insert(i) }
                i += 1; lastEnd = e; s = nx
                if cur >= nextFlush {
                    publish(&recs, &offs, &bad, i); nextFlush = cur + Self.flushEvery
                    if progress?(cur) == false { return false }
                }
            }
            if s == nil, k != .lines {   // another top-level value after the first one → JSONL saved as .json
                var j = Self.skipWS(b, k == .whole ? Self.valueEnd(b, base, n) : lastEnd, n)
                if k != .whole, j < n, b[j] == 0x5D || b[j] == 0x7D { j = Self.skipWS(b, j + 1, n) }
                if j < n, b[j] == 0x7B || b[j] == 0x5B { return true }
            }
            publish(&recs, &offs, &bad, i)
            return false
        }
        if isJSONL {
            lock.withLock { st = State(kind: .lines, base: 0) }
            index(maxRecords: maxRecords, progress: progress)
        }
    }

    private func publish(_ recs: inout [Int], _ offs: inout [Int], _ bad: inout Set<Int>, _ count: Int) {
        lock.withLock { st.recs += recs; st.offs += offs; st.count = count; st.bad.formUnion(bad) }
        recs = []; offs = []; bad = []
    }

    /// Bytes of record i: nearest index entry, then walk ≤64KB forward.
    public func range(of i: Int) -> Range<Int> {
        let (k, rec, off) = lock.withLock { () -> (Kind, Int, Int) in
            var lo = 0, hi = st.recs.count - 1          // last entry with recs[lo] <= i
            while lo < hi { let mid = (lo + hi + 1) / 2; if st.recs[mid] <= i { lo = mid } else { hi = mid - 1 } }
            return (st.kind, st.recs[lo], st.offs[lo])
        }
        return bytes { b, n in
            var s = off
            for _ in rec..<i { s = Self.step(k, b, s, n).next! }
            return s..<Self.step(k, b, s, n).end
        }
    }

    /// The value part of a record: drops `"key":` from object members.
    public func valueRange(_ r: Range<Int>) -> Range<Int> {
        guard kind == .object else { return r }
        return bytes { b, _ in
            let c = Self.skipWS(b, Self.valueEnd(b, r.lowerBound, r.upperBound), r.upperBound)
            return c < r.upperBound && b[c] == 0x3A ? Self.skipWS(b, c + 1, r.upperBound)..<r.upperBound : r
        }
    }

    /// Row label: the key for object members, "[i]" otherwise.
    public func name(_ i: Int, _ r: Range<Int>) -> String {
        guard kind == .object else { return "[\(i)]" }
        let end = bytes { b, _ in Self.valueEnd(b, r.lowerBound, r.upperBound) }
        let key = r.lowerBound..<end
        return parse(key) as? String ?? string(key)
    }

    public func parse(_ r: Range<Int>) -> Any? { try? JSONSerialization.jsonObject(with: data[r], options: [.fragmentsAllowed]) }

    /// Parsed value of record i. nil if invalid JSON or bigger than maxBytes.
    public func parsed(_ i: Int, maxBytes: Int = parseLimit) -> Any? {
        let r = valueRange(range(of: i))
        return r.count <= maxBytes ? parse(r) : nil
    }

    public func string(_ r: Range<Int>, max: Int = .max) -> String {
        String(decoding: data[r.lowerBound..<r.lowerBound + min(max, r.count)], as: UTF8.self)
    }
    public func raw(_ i: Int) -> String { string(range(of: i)) }
    public func preview(_ i: Int, max: Int = 200) -> String { string(range(of: i), max: max) }

    /// Matching record indices, or nil if `stop()` turned true. Plain = byte scan (memmem, or ASCII case fold).
    /// Runs on every core, 64 index entries (~4MB) per work item; `stop` is checked between batches.
    /// ponytail: hits are a plain [Int] (8B each) — a query matching billions of records costs GBs.
    public func search(_ needle: String, caseInsensitive: Bool, regex: Bool = false, stop: () -> Bool = { false }) throws -> [Int]? {
        let re = regex ? try NSRegularExpression(pattern: needle, options: caseInsensitive ? [.caseInsensitive] : []) : nil
        let (k, recs, offs, total) = lock.withLock { (st.kind, st.recs, st.offs, st.count) }
        if needle.isEmpty { return Array(0..<total) }
        let nd = Array((caseInsensitive && re == nil ? needle.lowercased() : needle).utf8)
        func matches(_ p: UnsafePointer<UInt8>, _ len: Int, _ re: NSRegularExpression?) -> Bool {
            if let re {
                let s = String(decoding: UnsafeBufferPointer(start: p, count: len), as: UTF8.self)
                return re.firstMatch(in: s, range: NSRange(location: 0, length: s.utf16.count)) != nil
            }
            if !caseInsensitive { return memmem(p, len, nd, nd.count) != nil }
            guard len >= nd.count else { return false }
            outer: for j in 0...(len - nd.count) {
                for t in 0..<nd.count {
                    var c = p[j + t]
                    if c >= 0x41, c <= 0x5A { c |= 0x20 }
                    if c != nd[t] { continue outer }
                }
                return true
            }
            return false
        }
        let per = 64, chunks = (recs.count + per - 1) / per, batch = ProcessInfo.processInfo.activeProcessorCount * 4
        let ahead = ReadAhead(url.path, from: offs.first ?? 0, to: data.count)
        defer { ahead.stop() }
        var hits: [Int] = []
        return bytes { b, n -> [Int]? in
            for c0 in stride(from: 0, to: chunks, by: batch) {
                if stop() { return nil }
                ahead.at(offs[c0 * per])
                var parts = [[Int]](repeating: [], count: min(batch, chunks - c0))
                parts.withUnsafeMutableBufferPointer { buf in
                    let out = buf
                    DispatchQueue.concurrentPerform(iterations: out.count) { t in autoreleasepool {   // regex makes autoreleased strings
                        let e0 = (c0 + t) * per, e1 = min(e0 + per, recs.count)
                        let last = e1 < recs.count ? recs[e1] : total
                        var i = recs[e0], s: Int? = offs[e0], found: [Int] = []
                        let re = re.flatMap { try? NSRegularExpression(pattern: $0.pattern, options: $0.options) }   // one per worker: a shared one serializes
                        while i < last, let cur = s {
                            let (e, nx) = Self.step(k, b, cur, n)
                            if matches(b + cur, e - cur, re) { found.append(i) }
                            i += 1; s = nx
                        }
                        out[t] = found
                    } }
                }
                hits += parts.joined()
            }
            return hits
        }
    }

    // MARK: byte walking

    private func bytes<T>(_ body: (UnsafePointer<UInt8>, Int) -> T) -> T {
        data.withUnsafeBytes { buf in
            guard let p = buf.baseAddress else { var z: UInt8 = 0; return body(&z, 0) }   // empty file
            return body(p.assumingMemoryBound(to: UInt8.self), buf.count)
        }
    }

    /// Record starting at s → where its bytes end, and where the next record starts (nil = last).
    private static func step(_ k: Kind, _ b: UnsafePointer<UInt8>, _ s: Int, _ n: Int) -> (end: Int, next: Int?) {
        switch k {
        case .lines:
            let hit = memchr(b + s, 0x0A, n - s).map { UnsafeRawPointer($0) - UnsafeRawPointer(b) }
            var e = hit ?? n
            if e > s, b[e - 1] == 0x0D { e -= 1 }
            guard let h = hit, h + 1 < n else { return (e, nil) }
            return (e, h + 1)
        case .whole:   // the rest of the file, minus trailing whitespace
            var e = n
            while e > s, b[e - 1] == 0x20 || b[e - 1] == 0x0A || b[e - 1] == 0x0D || b[e - 1] == 0x09 { e -= 1 }
            return (e, nil)
        case .array, .object:
            var e = valueEnd(b, s, n)
            if k == .object {   // "key" : value
                let c = skipWS(b, e, n)
                if c < n, b[c] == 0x3A { e = valueEnd(b, skipWS(b, c + 1, n), n) }
            }
            let j = skipWS(b, e, n)
            guard j < n, b[j] == 0x2C else { return (e, nil) }   // ] or } closes the top level (or EOF / junk)
            let nx = skipWS(b, j + 1, n)
            return (e, nx < n && b[nx] != 0x5D && b[nx] != 0x7D ? nx : nil)
        }
    }

    /// First byte after the JSON value at p. Tracks only strings and nesting, no validation.
    /// ponytail: byte-at-a-time (~1GB/s); memchr-skip strings if .json indexing speed matters.
    static func valueEnd(_ b: UnsafePointer<UInt8>, _ p: Int, _ n: Int) -> Int {
        var i = p, depth = 0
        while i < n {
            switch b[i] {
            case 0x22:                                    // string
                i += 1
                while i < n, b[i] != 0x22 { i += b[i] == 0x5C ? 2 : 1 }
                if depth == 0 { return min(i + 1, n) }
            case 0x7B, 0x5B: depth += 1
            case 0x7D, 0x5D:
                if depth == 0 { return i }                // a scalar ended at its parent's bracket
                depth -= 1
                if depth == 0 { return i + 1 }
            case 0x2C, 0x3A, 0x20, 0x0A, 0x0D, 0x09:      // , : whitespace end a scalar
                if depth == 0 { return i }
            default: break
            }
            i += 1
        }
        return n
    }

    private static func skipWS(_ b: UnsafePointer<UInt8>, _ p: Int, _ n: Int) -> Int {
        var p = p
        while p < n, b[p] == 0x20 || b[p] == 0x0A || b[p] == 0x0D || b[p] == 0x09 { p += 1 }
        return p
    }

    // ponytail: cheap check = trimmed line starts with { or [ and ends with } or ].
    // Full JSONSerialization only runs on shown/selected lines. Upgrade to full validation if false negatives bite.
    private static func looksLikeJSON(_ b: UnsafePointer<UInt8>, _ len: Int) -> Bool {
        var s = 0, e = len - 1
        while s <= e, b[s] == 0x20 || b[s] == 0x09 || b[s] == 0x0D { s += 1 }
        while e >= s, b[e] == 0x20 || b[e] == 0x09 || b[e] == 0x0D { e -= 1 }
        if s > e { return true }  // blank line: tolerate
        return (b[s] == 0x7B && b[e] == 0x7D) || (b[s] == 0x5B && b[e] == 0x5D)
    }
}

/// Reads the file ahead of a scan on a helper thread (pread → page cache), staying ≤1GB in front so pages aren't evicted
/// before use. A cold mmap scan otherwise faults page by page: 4GB indexed in ~5s → ~0.9s, searched in ~2s → ~0.7s
/// (disk speed). F_RDADVISE / MADV_WILLNEED measured slower.
private final class ReadAhead: @unchecked Sendable {
    private let lock = NSLock()
    private var pos = 0, done = false

    init(_ path: String, from: Int, to n: Int) {
        pos = from
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return }
        Thread.detachNewThread { [self] in
            let step = 8 << 20, buf = UnsafeMutableRawPointer.allocate(byteCount: step, alignment: 16)
            defer { buf.deallocate(); close(fd) }
            var o = from
            while o < n {
                let (p, stop) = lock.withLock { (pos, done) }
                if stop { return }
                if o > p + (1 << 30) { usleep(1000); continue }   // ponytail: poll; a condition variable if 1ms wakeups ever show up
                let r = pread(fd, buf, min(step, n - o), off_t(o))
                if r <= 0 { return }
                o += r
            }
        }
    }

    func at(_ p: Int) { lock.withLock { pos = p } }
    func stop() { lock.withLock { done = true } }
}
