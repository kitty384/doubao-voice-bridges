import AppKit

enum DeliveryPolicyTests {
    // Uses an isolated pasteboard; never touches .general or posts key events.
    static func run() -> [String] {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        var failures: [String] = []
        let transcript = "本轮语音测试 123"

        func check(_ result: Bool, _ expected: Bool, _ label: String) {
            if result != expected { failures.append("\(label): expected \(expected), got \(result)") }
        }

        func write(_ items: [NSPasteboardItem]) {
            pasteboard.clearContents()
            if !pasteboard.writeObjects(items) { failures.append("private pasteboard write failed") }
        }

        func plainText(_ text: String) -> NSPasteboardItem {
            let item = NSPasteboardItem()
            item.setString(text, forType: .string)
            return item
        }

        write([plainText(transcript)])
        let originalChangeCount = pasteboard.changeCount
        check(DeliveryClipboardPolicy.permitsPaste(
            from: pasteboard, expectedText: transcript, originalChangeCount: originalChangeCount
        ), true, "unchanged bridge generation")

        write([plainText(transcript)])
        check(pasteboard.changeCount != originalChangeCount, true, "same text rewrite changes generation")
        check(DeliveryClipboardPolicy.permitsPaste(
            from: pasteboard, expectedText: transcript, originalChangeCount: originalChangeCount
        ), true, "same single plain-text rewrite")

        write([plainText("上一轮或其他复制内容")])
        check(DeliveryClipboardPolicy.permitsPaste(
            from: pasteboard, expectedText: transcript, originalChangeCount: originalChangeCount
        ), false, "different text rejected")

        let mixedItem = plainText(transcript)
        mixedItem.setString("<p>本轮语音测试 123</p>", forType: .html)
        write([mixedItem])
        check(DeliveryClipboardPolicy.permitsPaste(
            from: pasteboard, expectedText: transcript, originalChangeCount: originalChangeCount
        ), false, "mixed formats rejected")

        write([plainText(transcript), plainText(transcript)])
        check(DeliveryClipboardPolicy.permitsPaste(
            from: pasteboard, expectedText: transcript, originalChangeCount: originalChangeCount
        ), false, "multiple items rejected")

        pasteboard.clearContents()
        check(DeliveryClipboardPolicy.permitsPaste(
            from: pasteboard, expectedText: transcript, originalChangeCount: originalChangeCount
        ), false, "empty rewrite rejected")

        check(DeliveryClipboardPolicy.isSafeSameTextRewrite(
            expectedText: transcript, actualText: transcript, itemTypes: [[.string]],
            beforeRead: 10, afterRead: 11
        ), false, "generation changing during read rejected")
        check(DeliveryClipboardPolicy.isSafeSameTextRewrite(
            expectedText: transcript, actualText: nil, itemTypes: [[.string]],
            beforeRead: 10, afterRead: 10
        ), false, "unreadable text rejected")

        return failures
    }
}
