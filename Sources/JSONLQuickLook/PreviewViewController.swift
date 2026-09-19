import Cocoa
import Quartz
import JSONLCore

/// Quick Look preview: (1) record count + keys, (2) record [0] pretty-printed. Same colors as the app.
@objc(PreviewViewController)
final class PreviewViewController: NSViewController, QLPreviewingController {
    let textView = NSTextView()
    let sampleRecords = 1000
    let fullCountLimit = 1 << 30   // ponytail: count every line up to 1GB (~1s); above that estimate from the sample

    override func loadView() {
        let sv = NSScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        sv.hasVerticalScroller = true
        textView.isEditable = false; textView.isRichText = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 12, height: 12)
        sv.documentView = textView
        view = sv
    }

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        do {
            let f = try JSONLFile(url: url)
            let full = f.data.count <= fullCountLimit
            f.index(maxLines: full ? .max : sampleRecords)
            let sampled = min(f.lineCount, sampleRecords)
            let total = full ? f.lineCount : (sampled > 0 ? Int(Double(f.data.count) / (Double(f.lineStarts[sampled - 1]) / Double(max(sampled - 1, 1)))) : 0)

            // keys over the sample: name → (type of first non-null value, records containing it)
            var keys: [String: (type: String, count: Int)] = [:]
            var objects = 0
            for i in 0..<sampled {
                guard let d = f.parsed(i) as? [String: Any] else { continue }
                objects += 1
                for (k, v) in d {
                    var e = keys[k] ?? (type: "null", count: 0)
                    e.count += 1
                    if e.type == "null" { e.type = jsonTypeName(v) }
                    keys[k] = e
                }
            }

            let mono = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            let out = NSMutableAttributedString()
            func line(_ s: String, _ color: NSColor = .labelColor, bold: Bool = false) {
                out.append(NSAttributedString(string: s + "\n", attributes: [.font: bold ? NSFont.boldSystemFont(ofSize: 13) : mono, .foregroundColor: color]))
            }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? ""
            let fmt = NumberFormatter(); fmt.numberStyle = .decimal
            var head = "\(url.lastPathComponent)  ·  \(size)  ·  \(full ? "" : "~")\(fmt.string(from: total as NSNumber)!) records"
            if full, !f.badLines.isEmpty { head += "  ·  \(f.badLines.count) invalid" }
            line(head, .labelColor, bold: true)
            line("")

            line("Keys (\(keys.count))" + (objects < sampled ? "  ·  \(sampled - objects) of the first \(sampled) records are not objects" : "") + (full && sampled < f.lineCount ? "  ·  from the first \(sampled) records" : ""), .secondaryLabelColor, bold: true)
            let w = keys.keys.map(\.count).max() ?? 0
            for k in keys.keys.sorted() {
                let e = keys[k]!
                let pct = objects > 0 && e.count < objects ? "   \(e.count * 100 / objects)%" : ""
                let row = NSMutableAttributedString(string: "  " + k.padding(toLength: w + 3, withPad: " ", startingAt: 0), attributes: [.font: mono, .foregroundColor: NSColor.labelColor])
                row.append(NSAttributedString(string: e.type + pct + "\n", attributes: [.font: mono, .foregroundColor: NSColor.secondaryLabelColor]))
                out.append(row)
            }
            if keys.isEmpty { line(objects == 0 ? "  (records are not JSON objects)" : "  (none)", .secondaryLabelColor) }
            line("")

            line("Sample [0]", .secondaryLabelColor, bold: true)
            if f.lineCount == 0 { line("  (empty file)", .secondaryLabelColor) }
            else if let v = f.parsed(0) { out.append(highlightedJSON(prettyJSON(v, rendered: false), font: mono)) }
            else { line("⚠ invalid JSON: " + f.preview(0, max: 2000), .systemRed) }

            textView.textStorage?.setAttributedString(out)
            handler(nil)
        } catch { handler(error) }
    }
}
