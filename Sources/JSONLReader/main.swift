import SwiftUI
import UniformTypeIdentifiers
import JSONLCore

/// value is the parsed JSON, or a String for a string leaf / an invalid line's raw text.
struct Selection {
    let name: String; let path: String; let value: Any
    let id = UUID()
    init(name: String, path: String, value: Any) { self.name = name; self.path = path; self.value = value }
    init(_ n: Node) { self.init(name: n.name, path: n.path, value: n.value) }
    var isJSON: Bool { !(value is String) }
    func text(rendered: Bool, limit: Int = .max) -> String { (value as? String) ?? prettyJSON(value, rendered: rendered, limit: limit) }
}

/// Detail text in an NSTextView: lays out lazily, so an 11MB record shows in ~50ms.
/// (SwiftUI Text lays out everything up front: 100k chars ≈ 4s, 1M chars > 10min.)
struct DetailText: NSViewRepresentable {
    let sel: Selection?; let rendered: Bool
    final class Coordinator { var shown: (UUID, Bool)? }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let sv = NSTextView.scrollableTextView(); sv.drawsBackground = false
        let tv = sv.documentView as! NSTextView
        tv.isEditable = false; tv.drawsBackground = false; tv.textContainerInset = NSSize(width: 8, height: 8)
        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        let key = sel.map { ($0.id, rendered) }
        guard key?.0 != context.coordinator.shown?.0 || key?.1 != context.coordinator.shown?.1 else { return }   // body re-runs on every Model change
        context.coordinator.shown = key
        let font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let t = sel?.text(rendered: rendered, limit: 16 << 20) ?? ""   // ponytail: 16MB of pretty text; Copy gets all of it
        let out = sel?.isJSON == true ? highlightedJSON(t, font: font) : NSAttributedString(string: t, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        (sv.documentView as! NSTextView).textStorage?.setAttributedString(out)
    }
}

@MainActor
final class Model: ObservableObject {
    @Published var file: JSONLFile?
    @Published var indexing = false
    @Published var progress = 0.0             // fraction of bytes indexed
    @Published var count = 0                  // records indexed so far (grows while indexing)
    @Published var visible: [Int]?            // search hits (sorted); nil = every record
    @Published var searching = false
    @Published var generation = 0             // bump → record list reloads
    @Published var root: Node?                // tree of the selected record
    @Published var selection: Selection?      // what the detail pane shows
    var recordSelection: Selection?           // the selected record as a whole
    @Published var query = ""
    @Published var caseInsensitive = true
    @Published var useRegex = false
    @Published var jumpTo: Int?
    @Published var collapseAllRequest = false
    @Published var error: String?
    private var openTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?

    func open(_ url: URL) {
        openTask?.cancel(); searchTask?.cancel()
        file = nil; indexing = true; progress = 0; count = 0; visible = nil; searching = false
        root = nil; recordSelection = nil; selection = nil; query = ""; generation += 1
        openTask = Task.detached { [weak self] in
            do {
                let f = try JSONLFile(url: url)
                await MainActor.run { self?.file = f }
                f.index { done in   // the list fills in as the index grows
                    Task { @MainActor in
                        guard let self, self.file === f else { return }
                        self.count = f.count; self.progress = Double(done) / Double(max(f.data.count, 1))
                    }
                    return !Task.isCancelled
                }
                await MainActor.run { guard let self, self.file === f else { return }; self.count = f.count; self.indexing = false }
            } catch {
                await MainActor.run { self?.error = error.localizedDescription; self?.indexing = false }
            }
        }
    }

    /// A new search cancels the previous one, so an older, slower scan can't overwrite newer results.
    func runSearch() {
        guard let f = file, !indexing else { return }
        searchTask?.cancel()
        let q = query, ci = caseInsensitive, re = useRegex
        if q.isEmpty { searching = false; visible = nil; generation += 1; return }
        searching = true
        searchTask = Task.detached { [weak self] in
            do {
                let hits = try f.search(q, caseInsensitive: ci, regex: re, stop: { Task.isCancelled })
                await MainActor.run {
                    guard let self, !Task.isCancelled, let hits else { return }
                    self.visible = hits; self.searching = false; self.generation += 1
                }
            } catch {
                await MainActor.run { self?.searching = false; self?.error = "Invalid regex: \(error.localizedDescription)" }
            }
        }
    }

    /// Parse the chosen record for the tree and detail pane.
    /// ponytail: parses on the main thread; a record near parseLimit (256MB) takes ~1–2s. Move off-main if that bites.
    func selectRecord(_ i: Int) {
        guard let f = file else { return }
        let raw = f.range(of: i), v = f.valueRange(raw), name = f.name(i, raw)
        let path = f.kind == .object ? Node.keyPath(name) : name
        if v.count > JSONLFile.parseLimit {
            root = nil
            let size = ByteCountFormatter.string(fromByteCount: Int64(v.count), countStyle: .file)
            recordSelection = Selection(name: name, path: path, value: "⚠ \(size) record, too large to parse. First 1 MB:\n\n" + f.string(raw, max: 1 << 20))
        } else if let x = f.parse(v) {
            let n = Node(name: name, value: x, path: path)
            root = n; recordSelection = Selection(n)
        } else {
            root = nil; recordSelection = Selection(name: name, path: path, value: f.string(raw))
        }
        selection = recordSelection
    }

    /// List row showing record n, if it's in the list.
    func row(of n: Int) -> Int? {
        guard let v = visible else { return n >= 0 && n < count ? n : nil }
        var lo = 0, hi = v.count   // hits are sorted
        while lo < hi { let mid = (lo + hi) / 2; if v[mid] < n { lo = mid + 1 } else { hi = mid } }
        return lo < v.count && v[lo] == n ? lo : nil
    }

    func select(_ s: Selection?) { selection = s }

    func copySelection() {
        guard let s = selection else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s.text(rendered: false), forType: .string)
    }
}

struct ContentView: View {
    @StateObject var m = Model()
    @State private var gotoText = ""
    @AppStorage("showDetail") var showDetail = true
    @AppStorage("detailOnRight") var detailOnRight = false
    @AppStorage("renderEscapes") var renderEscapesOn = false

    var detail: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Detail").font(.caption).bold().foregroundStyle(.secondary)
                Spacer()
                Toggle("Render escapes (\\n, \\t)", isOn: $renderEscapesOn).toggleStyle(.checkbox).font(.caption)
                    .help("Show \\n, \\t and other escapes inside strings as real characters")
                Button("Copy") { m.copySelection() }.font(.caption).disabled(m.selection == nil)
                Picker("", selection: $detailOnRight) {
                    Image(systemName: "rectangle.bottomhalf.inset.filled").tag(false)
                    Image(systemName: "rectangle.righthalf.inset.filled").tag(true)
                }.pickerStyle(.segmented).frame(width: 70).help("Detail pane position")
                Button { showDetail = false } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).help("Hide detail (⇧⌘D)")
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.bar)
            Divider()
            DetailText(sel: m.selection, rendered: renderEscapesOn)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if m.file != nil {
                HSplitView {
                    RecordList(m: m).frame(minWidth: 200, idealWidth: 380)
                    Group {
                        if !showDetail {
                            OutlineView(m: m)
                        } else if detailOnRight {
                            HSplitView { OutlineView(m: m).frame(minWidth: 200); detail.frame(minWidth: 150, idealWidth: 400) }
                        } else {
                            VSplitView { OutlineView(m: m).frame(minHeight: 150); detail.frame(minHeight: 60, idealHeight: 180) }
                        }
                    }.frame(minWidth: 300)
                }
                Divider()
                HStack(spacing: 12) {
                    Spacer()
                    Text(m.selection?.path ?? "").font(.system(.caption, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }.padding(.leading, 8).padding(.trailing, 20).padding(.vertical, 3)
            } else if m.indexing {
                ProgressView("Indexing…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("Drop a .jsonl / .ndjson / .json file here or press ⌘O")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(m.file?.url.lastPathComponent ?? "JSONL Reader")
        .searchable(text: $m.query, placement: .toolbar, prompt: "Find in records")
        .onSubmit(of: .search) { m.runSearch() }
        .onChange(of: m.query) { if m.query.isEmpty { m.runSearch() } }
        .toolbar {
            ToolbarItemGroup {
                Toggle("Match Case", isOn: Binding(get: { !m.caseInsensitive }, set: { m.caseInsensitive = !$0 })).toggleStyle(.button)
                    .help("Search is case-sensitive when on")
                Toggle("Regex", isOn: $m.useRegex).toggleStyle(.button).help("Treat the search text as a regular expression")
                Button("Collapse All") { m.collapseAllRequest = true }.help("Collapse every expanded record")
                if !showDetail {
                    Button("Show Detail") { showDetail = true }.help("Show the detail pane (⇧⌘D)")
                }
                TextField("Go to record #", text: $gotoText).frame(width: 110)
                    .onSubmit { if let n = Int(gotoText) { m.jumpTo = n } }
                    .help("Type a record index and press Return")
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { items in
            guard let p = items.first else { return false }
            _ = p.loadObject(ofClass: URL.self) { url, _ in if let url { Task { @MainActor in m.open(url) } } }
            return true
        }
        .alert("Error", isPresented: .constant(m.error != nil)) { Button("OK") { m.error = nil } } message: { Text(m.error ?? "") }
        .onReceive(NotificationCenter.default.publisher(for: .openFile)) { n in if let u = n.object as? URL { AppDelegate.pending = nil; m.open(u) } }
        .onAppear { if let u = AppDelegate.pending { AppDelegate.pending = nil; m.open(u) } }
        .frame(minWidth: 700, minHeight: 400)
    }

    var status: String {
        guard let f = m.file else { return "" }
        var s = "\(m.count.formatted()) records"
        if m.indexing { s += " · indexing \(Int(m.progress * 100))%" }
        if f.badCount > 0 { s += " · \(f.badCount.formatted()) invalid" }
        if m.searching { s += " · searching…" } else if let v = m.visible { s += " · \(v.count.formatted()) matching" }
        return s
    }
}

extension Notification.Name { static let openFile = Notification.Name("openFile") }

final class AppDelegate: NSObject, NSApplicationDelegate {
    static var pending: URL?   // Finder may deliver the file before ContentView subscribes
    func application(_ app: NSApplication, open urls: [URL]) {
        guard let u = urls.first else { return }
        Self.pending = u
        NotificationCenter.default.post(name: .openFile, object: u)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct JSONLReaderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @AppStorage("showDetail") var showDetail = true
    @AppStorage("detailOnRight") var detailOnRight = false
    @AppStorage("renderEscapes") var renderEscapesOn = false
    var body: some Scene {
        WindowGroup { ContentView() }
            .commands {
                CommandGroup(after: .sidebar) {
                    Toggle("Show Detail Pane", isOn: $showDetail).keyboardShortcut("d", modifiers: [.command, .shift])
                    Picker("Detail Pane Position", selection: $detailOnRight) {
                        Text("Bottom").tag(false); Text("Right").tag(true)
                    }
                    Toggle("Render Escapes in Detail", isOn: $renderEscapesOn).keyboardShortcut("e", modifiers: [.command, .shift])
                    Divider()
                }
                CommandGroup(replacing: .newItem) {
                    Button("Open…") {
                        let p = NSOpenPanel()
                        p.allowedContentTypes = [UTType(filenameExtension: "jsonl") ?? .json, UTType(filenameExtension: "ndjson") ?? .json, .json, .plainText]
                        if p.runModal() == .OK, let u = p.url { NotificationCenter.default.post(name: .openFile, object: u) }
                    }.keyboardShortcut("o")
                }
            }
    }
}

if CommandLine.arguments.contains("--check") { selfCheck(); exit(0) }
if let i = CommandLine.arguments.firstIndex(of: "--bench") {   // ponytail: perf check for PRD §4; not user-facing
    let f = try! JSONLFile(url: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
    var t = Date(); f.index(); print("index \(f.count) records, \(f.badCount) bad: \(Date().timeIntervalSince(t))s")
    t = Date(); let h = try! f.search("needle", caseInsensitive: true)!; print("search \(h.count) hits: \(Date().timeIntervalSince(t))s")
    exit(0)
}
NSApplication.shared.setActivationPolicy(.regular)
JSONLReaderApp.main()

func selfCheck() {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("check.jsonl")
    try! """
    {"id":1,"text":"Hello"}
    {broken
      {"id":3,"text":"world"}  \r
    [1,2,3]

    {"id":5,"text":"HELLO again","meta":{"tags":["x","y"],"ok":true,"n":null}}

    """.write(to: tmp, atomically: true, encoding: .utf8)
    let f = try! JSONLFile(url: tmp); f.index()
    assert(f.count == 6, "lines \(f.count)")
    assert(f.badCount == 1 && f.isBad(1), "bad")
    assert(f.raw(2) == "  {\"id\":3,\"text\":\"world\"}  ", "raw2 \(f.raw(2))")
    assert(f.raw(5) == "{\"id\":5,\"text\":\"HELLO again\",\"meta\":{\"tags\":[\"x\",\"y\"],\"ok\":true,\"n\":null}}", "trailing newline")
    assert(prettyJSON(f.parsed(3)!, rendered: false) == "[\n  1,\n  2,\n  3\n]")
    assert(f.parsed(1) == nil)
    assert(try! f.search("hello", caseInsensitive: true) == [0, 5])
    assert(try! f.search("hello", caseInsensitive: false) == [])
    assert(try! f.search("Hello", caseInsensitive: false) == [0])
    assert(try! f.search("^\\[", caseInsensitive: false, regex: true) == [3])
    assert((try? f.search("(", caseInsensitive: false, regex: true)) == nil, "bad regex should throw")
    assert(try! f.search("", caseInsensitive: true)!.count == 6)
    assert(try! f.search("hello", caseInsensitive: true, stop: { true }) == nil, "cancelled search")
    // many records: sparse index (one entry per 64KB) + parallel search across entry runs
    let big = FileManager.default.temporaryDirectory.appendingPathComponent("check-big.jsonl")
    let lines = (0..<30_000).map { "{\"i\":\($0),\"t\":\"\($0 % 997 == 0 ? "Needle" : "hay")\",\"pad\":\"\(String(repeating: "x", count: $0 % 50))\"}" }
    try! (lines.joined(separator: "\n") + "\n").write(to: big, atomically: true, encoding: .utf8)
    let bf = try! JSONLFile(url: big); bf.index()
    assert(bf.count == 30_000 && bf.badCount == 0)
    for i in stride(from: 0, to: 30_000, by: 293) + [29_999] { assert(bf.raw(i) == lines[i], "big raw \(i)") }
    let want = (0..<30_000).filter { $0 % 997 == 0 }
    assert(try! bf.search("needle", caseInsensitive: true) == want && bf.search("Needle", caseInsensitive: false) == want, "big search")
    assert(try! bf.search("\"i\":(\\d+)7,\"t\":\"N", caseInsensitive: false, regex: true) == want.filter { $0 % 10 == 7 })
    let part = try! JSONLFile(url: big); part.index(maxRecords: 100); assert(part.count == 100)
    // tree
    let root = Node(name: "[5]", value: f.parsed(5)!, path: "[5]")
    assert(root.children.map(\.name) == ["id", "meta", "text"], "\(root.children.map(\.name))")
    let meta = root.children[1]
    assert(meta.path == "[5].meta" && meta.children.map(\.path) == ["[5].meta.n", "[5].meta.ok", "[5].meta.tags"], "\(meta.children.map(\.path))")
    assert(Node.summary(meta.children[1].value).0 == "true" && Node.summary(meta.children[0].value).0 == "null")
    assert(meta.children[2].children[1].path == "[5].meta.tags[1]")
    assert(Node.keyPath("a b") == "[\"a b\"]")
    assert(Node.inline(root.value).string == "{ id: 5, meta: {…3}, text: \"HELLO again\" }", Node.inline(root.value).string)
    assert(Node.inline(f.parsed(3)!).string == "[ 1, 2, 3 ]")
    let obj: [String: Any] = ["s": "a\nb\t\"q\" \\ \u{01} 한", "n": [1, 2.5, true, NSNull()], "e": [String: Any]()]
    let normal = prettyJSON(obj, rendered: false)
    assert(normal == "{\n  \"e\" : {},\n  \"n\" : [\n    1,\n    2.5,\n    true,\n    null\n  ],\n  \"s\" : \"a\\nb\\t\\\"q\\\" \\\\ \\u0001 한\"\n}", normal)
    let back = try! JSONSerialization.jsonObject(with: normal.data(using: .utf8)!) as! [String: Any]
    assert(back["s"] as! String == obj["s"] as! String, "round trip")
    let rendered = prettyJSON(obj, rendered: true)
    assert(rendered.contains("\"a\nb\t\\\"q\\\" \\\\ \\u0001 한\""), rendered)
    let hs = "{\n  \"a\" : \"x\",\n  \"n\" : -1.5e3,\n  \"t\" : true,\n  \"z\" : null\n}" as NSString
    let runs = jsonTokens(hs as String).map { hs.substring(with: $0.0) }
    assert(runs == ["\"a\"", "\"x\"", "\"n\"", "-1.5e3", "\"t\"", "true", "\"z\"", "null"], "\(runs)")
    // .json
    func json(_ text: String, splitAbove: Int = JSONLFile.parseLimit) -> JSONLFile {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("check.json")
        try! text.write(to: u, atomically: true, encoding: .utf8)
        let f = try! JSONLFile(url: u, splitAbove: splitAbove); f.index(); return f
    }
    var g = json("[\n {\"a\": 1},\n {\"a\": 2}\n]")
    assert(g.kind == .array && g.count == 2 && g.raw(1) == "{\"a\": 2}", "json array \(g.count) \(g.raw(0))")
    g = json("\u{FEFF}[{\"s\":\"a]\\\"},\"} , 2,\"x,y\",[3,[4]], {}, null ]")
    assert(g.count == 6 && (0..<6).map(g.raw) == ["{\"s\":\"a]\\\"},\"}", "2", "\"x,y\"", "[3,[4]]", "{}", "null"], "tricky array \((0..<g.count).map(g.raw))")
    assert(json("[]").count == 0 && json(" [ ] ").count == 0)
    g = json("[1, 2, {\"a\":"); assert(g.count == 3 && g.parsed(2) == nil, "truncated array")
    g = json("{\"only\": true}")
    assert(g.kind == .whole && g.count == 1 && (g.parsed(0) as? [String: Any])?["only"] as? Bool == true, "json object")
    g = json("{ \"a b\" : [1, 2] , \"c\":{\"d\":\"}\"}, \"e\": 3 }", splitAbove: 0)   // big object → one record per member
    assert(g.kind == .object && g.count == 3 && g.name(0, g.range(of: 0)) == "a b" && g.raw(1) == "\"c\":{\"d\":\"}\"}", "split object \((0..<g.count).map(g.raw))")
    assert((g.parsed(0) as? [Any])?.count == 2 && g.parsed(2) as? Int == 3 && g.name(2, g.range(of: 2)) == "e")
    assert(try! g.search("\"d\"", caseInsensitive: false) == [1])
    g = json("{\"a\":1}\n{\"a\":2}\n"); assert(g.kind == .lines && g.count == 2, "JSONL saved as .json")
    g = json("{\"a\":1}\n{\"a\":2}\n", splitAbove: 0); assert(g.kind == .lines && g.count == 2, "big JSONL saved as .json")
    g = json("[1]\n[2]\n"); assert(g.kind == .lines && g.count == 2, "JSONL of arrays saved as .json")
    let cut = prettyJSON(["k": String(repeating: "x", count: 100), "z": 1] as [String: Any], rendered: false, limit: 10)
    assert(cut.hasPrefix("{\n  \"k\" : \"xxx") && cut.contains("truncated") && !cut.contains("\"z\""), cut)
    print("selfCheck OK")
}
