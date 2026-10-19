import AppKit

enum DeliveryClipboardPolicy {
    static func permitsPaste(
        from pasteboard: NSPasteboard,
        expectedText: String,
        originalChangeCount: Int
    ) -> Bool {
        let beforeRead = pasteboard.changeCount
        guard beforeRead != originalChangeCount else { return true }

        // UU can rewrite an unchanged string while synchronizing. Accept only
        // one plain-text item, without HTML, files, or other representations.
        let items = pasteboard.pasteboardItems ?? []
        let itemTypes = items.map(\.types)
        let actualText = items.count == 1 ? items[0].string(forType: .string) : nil
        let afterRead = pasteboard.changeCount

        return isSafeSameTextRewrite(
            expectedText: expectedText,
            actualText: actualText,
            itemTypes: itemTypes,
            beforeRead: beforeRead,
            afterRead: afterRead
        )
    }

    static func isSafeSameTextRewrite(
        expectedText: String,
        actualText: String?,
        itemTypes: [[NSPasteboard.PasteboardType]],
        beforeRead: Int,
        afterRead: Int
    ) -> Bool {
        guard beforeRead == afterRead,
              itemTypes.count == 1,
              itemTypes[0].count == 1,
              itemTypes[0][0] == .string else { return false }
        return actualText == expectedText
    }
}
