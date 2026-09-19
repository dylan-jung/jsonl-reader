import AppKit
import SwiftUI
import JSONLCore

final class JSONOutlineView: NSOutlineView {
    var onCopy: (() -> Void)?
    @objc func copy(_ sender: Any?) { onCopy?() }
}

struct OutlineView: NSViewRepresentable {
    @ObservedObject var m: Model

    func makeCoordinator() -> Coordinator { Coordinator(m: m) }

    func makeNSView(context: Context) -> NSScrollView {
        let ov = JSONOutlineView()
        let c = context.coordinator
        c.outline = ov
        for (id, title, w) in [("name", "Name", 220.0), ("value", "Value", 600.0)] {
            let col = NSTableColumn(identifier: .init(id)); col.title = title; col.width = w; col.minWidth = 80
            ov.addTableColumn(col)
        }
        ov.outlineTableColumn = ov.tableColumns[0]
        ov.dataSource = c; ov.delegate = c
        ov.usesAlternatingRowBackgroundColors = true
        ov.gridStyleMask = [.solidHorizontalGridLineMask]
        ov.rowHeight = 20
        ov.autoresizesOutlineColumn = false
        ov.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        ov.allowsMultipleSelection = false
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
        if c.generation != m.generation {
            c.generation = m.generation; c.nodes.removeAll(); c.outline?.reloadData()
        }
        if let i = m.jumpTo, let ov = c.outline {
            DispatchQueue.main.async {
                m.jumpTo = nil
                let row = ov.row(forItem: NSNumber(value: i))
                guard row >= 0 else { return }
                ov.selectRowIndexes([row], byExtendingSelection: false); ov.scrollRowToVisible(row)
            }
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
        var generation = -1
        var nodes: [Int: Node?] = [:]     // line → parsed root (nil = invalid JSON)
        init(m: Model) { self.m = m }

        func root(_ line: Int) -> Node? {
            if let n = nodes[line] { return n }
            let n = m.file?.parsed(line).map { Node(name: "[\(line)]", value: $0, path: "[\(line)]") }
            nodes[line] = n
            return n
        }
        func node(_ item: Any?) -> Node? { (item as? Node) ?? (item as? NSNumber).flatMap { root($0.intValue) } }

        func outlineView(_ ov: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            item == nil ? m.visible.count : (node(item)?.children.count ?? 0)
        }
        func outlineView(_ ov: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            item == nil ? NSNumber(value: m.visible[index]) : node(item)!.children[index]
        }
        func outlineView(_ ov: NSOutlineView, isItemExpandable item: Any) -> Bool { node(item)?.isContainer ?? false }

        func outlineView(_ ov: NSOutlineView, viewFor col: NSTableColumn?, item: Any) -> NSView? {
            let id = col!.identifier
            let cell = (ov.makeView(withIdentifier: id, owner: nil) as? NSTableCellView) ?? Self.makeCell(id)
            let tf = cell.textField!
            tf.attributedStringValue = NSAttributedString()   // clear reused cell
            tf.maximumNumberOfLines = 1; tf.cell?.truncatesLastVisibleLine = true
            tf.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            let n = node(item)
            if id.rawValue == "name" {
                tf.stringValue = n?.name ?? "[\((item as! NSNumber).intValue)]"; tf.textColor = .labelColor
            } else if let n {
                tf.attributedStringValue = Node.inline(n.value)
            } else if let f = m.file {
                tf.stringValue = "⚠ invalid JSON: " + f.preview(line: item, max: 300); tf.textColor = .systemRed
            }
            return cell
        }

        static func makeCell(_ id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
            let cell = NSTableCellView(); cell.identifier = id
            let tf = NSTextField(labelWithString: ""); tf.lineBreakMode = .byTruncatingTail; tf.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(tf); cell.textField = tf
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
            return cell
        }

        func outlineViewSelectionDidChange(_ n: Notification) {
            guard let ov = outline, ov.selectedRow >= 0, let item = ov.item(atRow: ov.selectedRow) else { m.select(nil); return }
            m.select(selection(for: item))
        }

        func selection(for item: Any) -> Selection {
            if let n = item as? Node { return Selection(name: n.name, path: n.path, value: n.value) }
            let line = (item as! NSNumber).intValue
            if let n = root(line) { return Selection(name: n.name, path: n.path, value: n.value) }
            return Selection(name: "[\(line)]", path: "[\(line)]", value: m.file?.raw(line) ?? "")
        }

        @objc func menuCopy(_ sender: NSMenuItem) { copy(What(rawValue: sender.tag)!, row: outline?.clickedRow ?? -1) }

        func copy(_ what: What, row: Int = -1) {
            guard let ov = outline else { return }
            let r = row >= 0 ? row : ov.selectedRow
            guard r >= 0, let item = ov.item(atRow: r) else { return }
            let s = selection(for: item)
            let text = switch what { case .name: s.name; case .value: s.text(rendered: false); case .path: s.path }
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        }
    }
}
