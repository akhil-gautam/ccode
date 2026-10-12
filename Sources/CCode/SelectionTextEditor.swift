import SwiftUI
import AppKit

struct SelectionTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var selection: NSRange
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.drawsBackground = false; scroll.hasVerticalScroller = true
        let editor = NSTextView(); editor.string = text; editor.delegate = context.coordinator
        editor.isRichText = false; editor.isAutomaticQuoteSubstitutionEnabled = false; editor.isAutomaticDashSubstitutionEnabled = false
        editor.font = .monospacedSystemFont(ofSize: 12, weight: .regular); editor.textColor = .labelColor; editor.drawsBackground = false
        editor.textContainerInset = NSSize(width: 12, height: 12); editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        editor.setAccessibilityLabel("File contents")
        scroll.documentView = editor
        context.coordinator.update(editor)
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? NSTextView else { return }
        context.coordinator.update(editor)
    }
    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SelectionTextEditor
        var updating = false
        init(_ parent: SelectionTextEditor) { self.parent = parent }
        func update(_ editor: NSTextView) {
            updating = true
            defer { updating = false }
            if editor.string != parent.text { editor.string = parent.text }
            let length = (editor.string as NSString).length
            let location = parent.selection.location == NSNotFound ? 0 : min(parent.selection.location, length)
            let range = NSRange(location: location, length: min(parent.selection.length, length - location))
            if editor.selectedRange() != range {
                editor.setSelectedRange(range); editor.scrollRangeToVisible(range)
            }
        }
        func textDidChange(_ notification: Notification) {
            guard !updating, let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string; parent.selection = editor.selectedRange()
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard !updating, let editor = notification.object as? NSTextView else { return }
            parent.selection = editor.selectedRange()
        }
    }
}
