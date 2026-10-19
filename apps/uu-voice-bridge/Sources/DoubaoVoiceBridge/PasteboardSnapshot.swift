import AppKit

struct PasteboardSnapshot {
    private static let maximumBytes = 16 * 1024 * 1024
    private let items: [[NSPasteboard.PasteboardType: Data]]

    static func capture(from pasteboard: NSPasteboard) -> PasteboardSnapshot? {
        var capturedItems: [[NSPasteboard.PasteboardType: Data]] = []
        var totalBytes = 0

        for item in pasteboard.pasteboardItems ?? [] {
            var captured: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                guard let data = item.data(forType: type) else { return nil }
                totalBytes += data.count
                guard totalBytes <= maximumBytes else { return nil }
                captured[type] = data
            }
            capturedItems.append(captured)
        }

        return PasteboardSnapshot(items: capturedItems)
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }

        let restoredItems = items.map { values -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in values {
                item.setData(data, forType: type)
            }
            return item
        }
        pasteboard.writeObjects(restoredItems)
    }
}
