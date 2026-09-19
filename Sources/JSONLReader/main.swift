import SwiftUI
import UniformTypeIdentifiers
import JSONLCore

/// value is the parsed JSON, or a String for a string leaf / an invalid line's raw text.
struct Selection {
    let name: String; let path: String; let value: Any
    var isJSON: Bool { !(value is String) }
    func text(rendered: Bool) -> String { (value as? String) ?? prettyJSON(value, rendered: rendered) }
}

/// Syntax-color pretty-printed JSON. Same palette as the tree.
func highlightJSON(_ s: String) -> AttributedString {
    var out = AttributedString(s)
    for (r, c) in jsonTokens(s) {
        if let sr = Range(r, in: s), let ar = Range(sr, in: out) { out[ar].foregroundColor = Color(nsColor: c) }
    }
    return out
}

@MainActor
final class Model: ObservableObject {
    @Published var file: JSONLFile?
    @Published var indexing = false
    @Published var visible: [Int] = []        // record indices currently shown (after search)
    @Published var generation = 0             // bump → outline reloads
    @Published var selection: Selection?
    @Published var query = ""
    @Published var caseInsensitive = true
    @Published var useRegex = false
    @Published var jumpTo: Int?
    @Published var collapseAllRequest = false
    @Published var error: String?

    func open(_ url: URL) {
        indexing = true; selection = nil; visible = []; query = ""; generation += 1
        Task.detached { [weak self] in
            do {
                let f = try JSONLFile(url: url)
                f.index()
                await MainActor.run { self?.file = f; self?.visible = Array(0..<f.lineCount); self?.generation += 1; self?.indexing = false }
            } catch {
                await MainActor.run { self?.error = error.localizedDescription; self?.indexing = false }
            }
        }
    }

    func runSearch() {
        guard let f = file else { return }
        let q = query, ci = caseInsensitive, re = useRegex
        Task.detached { [weak self] in
            do {
                let hits = try f.search(q, caseInsensitive: ci, regex: re)
                await MainActor.run { self?.visible = hits; self?.selection = nil; self?.generation += 1 }
            } catch {
                await MainActor.run { self?.error = "Invalid regex: \(error.localizedDescription)" }
            }
        }
    }

    func select(_ s: Selection?) { selection = s }
}

struct ContentView: View {
    @StateObject var m = Model()
    @State private var gotoText = ""
    @AppStorage("showDetail") var showDetail = true
    @AppStorage("detailOnRight") var detailOnRight = false
    @AppStorage("renderEscapes") var renderEscapesOn = false

    var detailText: AttributedString {
        guard let sel = m.selection else { return AttributedString() }
        let t = sel.text(rendered: renderEscapesOn)
        return sel.isJSON ? highlightJSON(t) : AttributedString(t)
    }

    var detail: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Detail").font(.caption).bold().foregroundStyle(.secondary)
                Spacer()
                Toggle("Render escapes (\\n, \\t)", isOn: $renderEscapesOn).toggleStyle(.checkbox).font(.caption)
                    .help("Show \\n, \\t and other escapes inside strings as real characters")
                Button("Copy") {
                    guard let sel = m.selection else { return }
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(sel.text(rendered: false), forType: .string)
                }.font(.caption).disabled(m.selection == nil)
                Picker("", selection: $detailOnRight) {
                    Image(systemName: "rectangle.bottomhalf.inset.filled").tag(false)
                    Image(systemName: "rectangle.righthalf.inset.filled").tag(true)
                }.pickerStyle(.segmented).frame(width: 70).help("Detail pane position")
                Button { showDetail = false } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).help("Hide detail (⇧⌘D)")
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.bar)
            Divider()
            ScrollView {
                Text(detailText)
                    .font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if m.file != nil {
                if !showDetail {
                    OutlineView(m: m)
                } else if detailOnRight {
                    HSplitView { OutlineView(m: m).frame(minWidth: 300); detail.frame(minWidth: 150, idealWidth: 400) }
                } else {
                    VSplitView { OutlineView(m: m).frame(minHeight: 150); detail.frame(minHeight: 60, idealHeight: 180) }
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
                    .onSubmit { if let n = Int(gotoText), m.visible.contains(n) { m.jumpTo = n } }
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
        var s = "\(f.lineCount) records"
        if !f.badLines.isEmpty { s += " · \(f.badLines.count) invalid" }
        if m.visible.count != f.lineCount { s += " · \(m.visible.count) matching" }
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
    var t = Date(); f.index(); print("index \(f.lineCount) lines, \(f.badLines.count) bad: \(Date().timeIntervalSince(t))s")
    t = Date(); let h = try! f.search("needle", caseInsensitive: true); print("search \(h.count) hits: \(Date().timeIntervalSince(t))s")
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
    assert(f.lineCount == 6, "lines \(f.lineCount)")
    assert(f.badLines == [1], "bad \(f.badLines)")
    assert(f.raw(2) == "  {\"id\":3,\"text\":\"world\"}  ", "raw2 \(f.raw(2))")
    assert(f.raw(5) == "{\"id\":5,\"text\":\"HELLO again\",\"meta\":{\"tags\":[\"x\",\"y\"],\"ok\":true,\"n\":null}}", "trailing newline")
    assert(f.pretty(3) == "[\n  1,\n  2,\n  3\n]", "pretty3 \(f.pretty(3) ?? "nil")")
    assert(f.pretty(1) == nil)
    assert(try! f.search("hello", caseInsensitive: true) == [0, 5])
    assert(try! f.search("hello", caseInsensitive: false) == [])
    assert(try! f.search("Hello", caseInsensitive: false) == [0])
    assert(try! f.search("^\\[", caseInsensitive: false, regex: true) == [3])
    assert((try? f.search("(", caseInsensitive: false, regex: true)) == nil, "bad regex should throw")
    assert(try! f.search("", caseInsensitive: true).count == 6)
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
    let hl = highlightJSON("{\n  \"a\" : \"x\",\n  \"n\" : -1.5e3,\n  \"t\" : true,\n  \"z\" : null\n}")
    let runs = hl.runs.filter { $0.foregroundColor != nil }.map { String(hl[$0.range].characters) }
    assert(runs == ["\"a\"", "\"x\"", "\"n\"", "-1.5e3", "\"t\"", "true", "\"z\"", "null"], "\(runs)")
    // .json
    let js = FileManager.default.temporaryDirectory.appendingPathComponent("check.json")
    try! "[\n {\"a\": 1},\n {\"a\": 2}\n]".write(to: js, atomically: true, encoding: .utf8)
    let g = try! JSONLFile(url: js); g.index()
    assert(g.lineCount == 2 && g.badLines.isEmpty && g.raw(1) == "{\"a\":2}", "json array \(g.lineCount) \(g.raw(0))")
    try! "{\"only\": true}".write(to: js, atomically: true, encoding: .utf8)
    let h = try! JSONLFile(url: js); h.index()
    assert(h.lineCount == 1 && h.pretty(0) != nil, "json object")
    print("selfCheck OK")
}
