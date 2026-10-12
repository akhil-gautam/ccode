import AppKit
import SwiftUI

/// A non-consuming boundary: mouse focus is updated before a control handles its action.
struct ChatPaneFocusBoundary: NSViewRepresentable {
    var requestID: UUID? = nil
    let focus: @MainActor () -> Void
    func makeNSView(context: Context) -> ChatPaneFocusView {
        let view = ChatPaneFocusView(); view.focus = focus; return view
    }
    func updateNSView(_ view: ChatPaneFocusView, context: Context) {
        view.focus = focus
        view.requestPromptFocus(requestID)
    }
    static func dismantleNSView(_ view: ChatPaneFocusView, coordinator: ()) { view.stopObserving() }
}

@MainActor final class ChatPaneFocusView: NSView {
    var focus: (@MainActor () -> Void)?
    private var mouseMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private weak var lastResponder: NSResponder?
    private var focusRequestID: UUID?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopObserving()
        guard let window else { return }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                if let self, event.window === self.window, !self.isHiddenOrHasHiddenAncestor,
                   self.bounds.contains(self.convert(event.locationInWindow, from: nil)) { self.focus?() }
            }
            return event
        }
        for name in [NSWindow.didUpdateNotification, NSWindow.didBecomeKeyNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let window = self.window, window.isKeyWindow, let responder = window.firstResponder,
                          responder !== self.lastResponder else { return }
                    self.lastResponder = responder
                    if self.ownsResponder(responder) {
                        Task { @MainActor [weak self] in
                            guard let self, self.window?.firstResponder === responder else { return }
                            self.focus?()
                        }
                    }
                }
            })
        }
    }
    func ownsResponder(_ responder: NSResponder) -> Bool {
        guard let window else { return false }
        // AppKit's shared field editor delegates to the text field that actually owns focus.
        let source: NSView?
        if let editor = responder as? NSTextView, editor.isFieldEditor, let field = editor.delegate as? NSView { source = field }
        else { source = responder as? NSView }
        guard let source, source.window === window, source !== window.contentView, !source.bounds.isEmpty,
              !isHiddenOrHasHiddenAncestor else { return false }
        let rectangle = source.convert(source.bounds, to: nil)
        return bounds.contains(convert(NSPoint(x: rectangle.midX, y: rectangle.midY), from: nil))
    }
    func requestPromptFocus(_ id: UUID?) {
        guard let id, focusRequestID != id else { return }
        focusRequestID = id
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, self.focusRequestID == id, self.window?.isKeyWindow == true else { return }
            _ = self.focusPrompt()
        }
    }
    @discardableResult func focusPrompt() -> Bool {
        guard let content = window?.contentView else { return false }
        func find(_ view: NSView) -> InputTextView? {
            if let input = view as? InputTextView, input.identifier?.rawValue == "ccode.mainPrompt", input.isEditable, ownsResponder(input) { return input }
            for child in view.subviews { if let input = find(child) { return input } }
            return nil
        }
        guard let input = find(content) else { return false }
        return window?.makeFirstResponder(input) == true
    }
    func stopObserving() {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []; lastResponder = nil
    }
}
