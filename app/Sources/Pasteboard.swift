import AppKit

/// A faithful snapshot of the whole pasteboard: every item with every representation it
/// carries (plain text, RTF, HTML, images, file URLs, several items at once).
///
/// The snippet paths used to save only `string(forType: .string)` and write that back, so a
/// clipboard holding an image, a file reference or a non-text flavour came back **empty** —
/// "the snippet ate my clipboard". Restoring also has to be conditional: if anything else
/// writes to the pasteboard while we are pasting, that newer content must win.
struct PasteboardSnapshot {
    private let items: [[NSPasteboard.PasteboardType: Data]]
    private let wasEmpty: Bool

    static func capture(_ pasteboard: NSPasteboard = .general) -> PasteboardSnapshot {
        var captured: [[NSPasteboard.PasteboardType: Data]] = []
        for item in pasteboard.pasteboardItems ?? [] {
            var representations: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    representations[type] = data
                }
            }
            if !representations.isEmpty { captured.append(representations) }
        }
        return PasteboardSnapshot(items: captured, wasEmpty: captured.isEmpty)
    }

    var typeCount: Int { items.reduce(0) { $0 + $1.count } }
    var itemCount: Int { items.count }

    var summary: String {
        wasEmpty ? "空" : "\(items.count) 项 / \(typeCount) 种类型"
    }

    /// Writes the snapshot back only while the pasteboard still holds what we put there.
    /// `ownership` is the changeCount observed immediately after our own write.
    @discardableResult
    func restore(to pasteboard: NSPasteboard = .general, ifUnchangedSince ownership: Int) -> Bool {
        guard pasteboard.changeCount == ownership else {
            Log.write("clipboard not restored: it changed after our write (newer content wins)")
            return false
        }
        pasteboard.clearContents()
        guard !wasEmpty else {
            Log.write("clipboard restored to its previous (empty) state")
            return true
        }
        let objects: [NSPasteboardItem] = items.map { representations in
            let item = NSPasteboardItem()
            for (type, data) in representations {
                item.setData(data, forType: type)
            }
            return item
        }
        pasteboard.writeObjects(objects)
        Log.write("clipboard restored (\(summary))")
        return true
    }
}
