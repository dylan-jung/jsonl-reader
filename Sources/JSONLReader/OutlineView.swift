import AppKit
import SwiftUI
import JSONLCore

/// Reused one-line monospaced cell for both tables.
@MainActor
func textCell(_ tv: NSTableView, _ id: NSUserInterfaceItemIdentifier) -> (NSTableCellView, NSTextField) {
    let cell = (tv.makeView(withIdentifier: id, owner: nil) as? NSTableCellView) ?? {
        let cell = NSTableCellView(); cell.identifier = id
        let tf = NSTextField(labelWithString: ""); tf.lineBreakMode = .byTruncatingTail; tf.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(tf); cell.textField = tf
        NSLayoutConstraint.activate([
            tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        return cell
    }()
    let tf = cell.textField!
    tf.attributedStringValue = NSAttributedString()   // clear reused cell
    tf.maximumNumberOfLines = 1; tf.cell?.truncatesLastVisibleLine = true
    tf.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    return (cell, tf)
}

@MainActor
func addColumns(_ tv: NSTableView, _ cols: [(String, String, Double)]) {
    for (id, title, w) in cols {
        let col = NSTableColumn(identifier: .init(id)); col.title = title; col.width = w; col.minWidth = 60
        tv.addTableColumn(col)
    }
    tv.usesAlternatingRowBackgroundColors = true
    tv.gridStyleMask = [.solidHorizontalGridLineMask]
    tv.rowHeight = 20
    tv.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
    tv.allowsMultipleSelection = false
}

final class RecordTable: NSTableView {
    var onCopy: (() -> Void)?
    @objc func copy(_ sender: Any?) { onCopy?() }
}

/// Left pane: one row per record. NSTableView only asks for visible rows, so 2B records cost the same as 20.
/// (NSOutlineView fetches every root item on reload: 50M rows ≈ 2s and ~5GB.)
struct RecordList: NSViewRepresentable {
    @ObservedObject var m: Model

    func makeCoordinator() -> Coordinator { Coordinator(m: m) }

    func makeNSView(context: Context) -> NSScrollView {
        let tv = RecordTable()
        let c = context.coordinator
        c.table = tv
        addColumns(tv, [("name", "#", 100), ("value", "Record", 400)])
        tv.dataSource = c; tv.delegate = c
        tv.onCopy = { [weak m] in m?.copySelection() }
        let sv = NSScrollView()
        sv.documentView = tv; sv.hasVerticalScroller = true; sv.hasHorizontalScroller = false
        tv.sizeLastColumnToFit()
        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        let c = context.coordinator
        guard let tv = c.table else { return }
        if c.generation != m.generation {
            c.generation = m.generation; tv.deselectAll(nil); tv.reloadData()
        } else if tv.numberOfRows != c.rows {
            tv.noteNumberOfRowsChanged()   // index grew
        }
        if let n = m.jumpTo {
            DispatchQueue.main.async {
                m.jumpTo = nil
                guard let row = m.row(of: n) else { return }
                tv.selectRowIndexes([row], byExtendingSelection: false); tv.scrollRowToVisible(row)
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        let m: Model
        weak var table: RecordTable?
        var generation = -1
        init(m: Model) { self.m = m }

        var rows: Int { m.visible?.count ?? m.count }
        func record(_ row: Int) -> Int { m.visible?[row] ?? row }

        func numberOfRows(in tv: NSTableView) -> Int { rows }

        func tableView(_ tv: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
            guard let f = m.file else { return nil }
            let id = col!.identifier, i = record(row), raw = f.range(of: i)
            let (cell, tf) = textCell(tv, id)
            if id.rawValue == "name" { tf.stringValue = f.name(i, raw); tf.textColor = .labelColor; return cell }
            // ponytail: rows ≤16KB are parsed for the colored preview; bigger ones show raw bytes so scrolling never parses MBs.
            let v = f.valueRange(raw), small = v.count <= 16 << 10
            if small, let x = f.parse(v) {
                tf.attributedStringValue = Node.inline(x)
            } else if small || f.isBad(i) {
                tf.stringValue = "⚠ invalid JSON: " + oneLine(f.string(raw, max: 300)); tf.textColor = .systemRed
            } else {
                tf.stringValue = oneLine(f.string(raw, max: 300)); tf.textColor = .labelColor
            }
            return cell
        }

        /// Raw bytes for a one-line cell: whitespace runs (pretty-printed newlines) become one space.
        func oneLine(_ s: String) -> String { s.split(whereSeparator: \.isWhitespace).joined(separator: " ") }

        func tableViewSelectionDidChange(_ n: Notification) {
            guard let tv = table, tv.selectedRow >= 0 else { return }
            m.selectRecord(record(tv.selectedRow))
        }
    }
}

final class JSONOutlineView: NSOutlineView {
    var onCopy: (() -> Void)?
    @objc func copy(_ sender: Any?) { onCopy?() }
}

/// Tree of the selected record.
struct OutlineView: NSViewRepresentable {
    @ObservedObject var m: Model

    func makeCoordinator() -> Coordinator { Coordinator(m: m) }

    func makeNSView(context: Context) -> NSScrollView {
        let ov = JSONOutlineView()
        let c = context.coordinator
        c.outline = ov
        addColumns(ov, [("name", "Name", 220), ("value", "Value", 600)])
        ov.outlineTableColumn = ov.tableColumns[0]
        ov.autoresizesOutlineColumn = false
        ov.dataSource = c; ov.delegate = c
        ov.onCopy = { c.copy(.value) }
        let menu = NSMenu()
        for (t, k) in [("Copy Name", Coordinator.What.name), ("Copy Value", .value), ("Copy Path", .path)] {
            let it = NSMenuItem(title: t, action: #selector(Coordinator.menuCopy(_:)), keyEquivalent: ""); it.target = c; it.tag = k.rawValue
            menu.addItem(it)
        }
        ov.menu = menu
        let sv = NSScrollView()
        sv.documentView = ov; sv.hasVerticalScroller = true; sv.hasHorizontalScroller = false
        ov.sizeLastColumnToFit()
        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        let c = context.coordinator
        if c.root !== m.root, let ov = c.outline {
            c.root = m.root; ov.reloadData(); ov.deselectAll(nil)
        }
        if m.collapseAllRequest, let ov = c.outline {
            DispatchQueue.main.async { m.collapseAllRequest = false; ov.collapseItem(nil, collapseChildren: true) }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        enum What: Int { case name, value, path }
        let m: Model
        weak var outline: JSONOutlineView?
        var root: Node?
        init(m: Model) { self.m = m }

        func node(_ item: Any?) -> Node? { (item as? Node) ?? root }

        func outlineView(_ ov: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { node(item)?.children.count ?? 0 }
        func outlineView(_ ov: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { node(item)!.children[index] }
        func outlineView(_ ov: NSOutlineView, isItemExpandable item: Any) -> Bool { (item as! Node).isContainer }

        func outlineView(_ ov: NSOutlineView, viewFor col: NSTableColumn?, item: Any) -> NSView? {
            let n = item as! Node
            let (cell, tf) = textCell(ov, col!.identifier)
            if col!.identifier.rawValue == "name" { tf.stringValue = n.name; tf.textColor = .labelColor }
            else { tf.attributedStringValue = Node.inline(n.value) }
            return cell
        }

        func outlineViewSelectionDidChange(_ n: Notification) {
            guard let ov = outline, ov.selectedRow >= 0, let n = ov.item(atRow: ov.selectedRow) as? Node else {
                if m.selection?.id != m.recordSelection?.id { m.select(m.recordSelection) }   // back to the whole record
                return
            }
            m.select(Selection(n))
        }

        @objc func menuCopy(_ sender: NSMenuItem) { copy(What(rawValue: sender.tag)!, row: outline?.clickedRow ?? -1) }

        func copy(_ what: What, row: Int = -1) {
            guard let ov = outline else { return }
            let r = row >= 0 ? row : ov.selectedRow
            guard r >= 0, let n = ov.item(atRow: r) as? Node else { return }
            let s = Selection(n)
            let text = switch what { case .name: s.name; case .value: s.text(rendered: false); case .path: s.path }
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        }
    }
}
