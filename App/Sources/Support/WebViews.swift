import SwiftUI
import WebKit
import SlyyMailKit

#if os(macOS)
typealias PlatformViewRepresentable = NSViewRepresentable
#else
typealias PlatformViewRepresentable = UIViewRepresentable
#endif

func openExternally(_ url: URL) {
    #if os(macOS)
    NSWorkspace.shared.open(url)
    #else
    UIApplication.shared.open(url)
    #endif
}

/// Renders mail HTML with JavaScript off, a throwaway data store, and a CSP that blocks
/// every remote load (tracking pixels, CSS url(), fonts) until the user allows images.
struct MailHTMLView: PlatformViewRepresentable {
    let html: String
    let allowRemoteContent: Bool
    /// Text size of the mail body (⌘+ / ⌘−), 1 = 100 %.
    var zoom: CGFloat = 1
    /// Reports the document height (accordion sections size themselves to their mail).
    var onHeight: ((CGFloat) -> Void)? = nil
    var onMailto: (URL) -> Void = { _ in }
    /// Reports the selected text whenever the selection changes ("" when nothing is selected),
    /// so Reply / Forward can quote just that part.
    var onSelection: ((String) -> Void)? = nil

    /// Name of the script message handler that receives the selection.
    static let selectionHandler = "slyySelection"
    /// App-side script in its own content world (page scripts stay disabled and cannot see it).
    static let selectionScript = """
    document.addEventListener('selectionchange', function () {
        window.webkit.messageHandlers.\(MailHTMLView.selectionHandler).postMessage(String(window.getSelection() || ''));
    });
    """

    static func document(_ body: String, allowRemote: Bool) -> String {
        let img = allowRemote ? "data: cid: https: http:" : "data: cid:"
        let csp = "default-src 'none'; img-src \(img); style-src 'unsafe-inline'\(allowRemote ? " https:" : ""); font-src data:\(allowRemote ? " https:" : ""); media-src 'none'; script-src 'none'; frame-src 'none'; form-action 'none'"
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\(csp)">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        html { -webkit-text-size-adjust: 100%; }
        body { font: -apple-system-body; font-family: -apple-system, system-ui, sans-serif; margin: 16px; word-wrap: break-word; overflow-wrap: anywhere; background: #fff; color: #111; }
        img { max-width: 100%; height: auto; }
        pre, code { white-space: pre-wrap; }
        blockquote { border-left: 3px solid #c8c8c8; margin-left: 0; padding-left: 12px; color: #555; }
        table { max-width: 100%; }
        </style></head><body>\(body)</body></html>
        """
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    private func makeWebView(_ context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        if onSelection != nil {
            let scripts = config.userContentController
            scripts.addUserScript(WKUserScript(source: Self.selectionScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
            // Through a weak proxy: the content controller keeps its handlers alive.
            scripts.add(WeakScriptMessageHandler(context.coordinator), contentWorld: .defaultClient, name: Self.selectionHandler)
        }
        let web = MailWebView(frame: .zero, configuration: config)
        // Sized to its whole mail inside a scrolling page (conversations): the page scrolls, not the web view.
        let fitsContent = onHeight != nil
        #if os(macOS)
        web.passesScrollToPage = fitsContent
        #else
        web.scrollView.isScrollEnabled = !fitsContent
        #endif
        web.navigationDelegate = context.coordinator
        load(web, context: context)
        return web
    }

    #if os(macOS)
    func makeNSView(context: Context) -> WKWebView { makeWebView(context) }
    func updateNSView(_ web: WKWebView, context: Context) { load(web, context: context) }
    static func dismantleNSView(_ web: WKWebView, coordinator: Coordinator) { dismantle(web, coordinator) }
    #else
    func makeUIView(context: Context) -> WKWebView { makeWebView(context) }
    func updateUIView(_ web: WKWebView, context: Context) { load(web, context: context) }
    static func dismantleUIView(_ web: WKWebView, coordinator: Coordinator) { dismantle(web, coordinator) }
    #endif

    /// A mail that is no longer shown has no selection to quote.
    static func dismantle(_ web: WKWebView, _ coordinator: Coordinator) {
        web.configuration.userContentController.removeAllScriptMessageHandlers()
        if let report = coordinator.parent.onSelection { DispatchQueue.main.async { report("") } }
    }

    private func load(_ web: WKWebView, context: Context) {
        context.coordinator.parent = self
        if web.pageZoom != zoom {
            web.pageZoom = zoom
            context.coordinator.measure(web) // the same mail at another size needs another height
        }
        let doc = Self.document(html, allowRemote: allowRemoteContent)
        guard context.coordinator.loaded != doc else { return }
        context.coordinator.loaded = doc
        web.loadHTMLString(doc, baseURL: nil)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: MailHTMLView
        var loaded: String?

        init(_ parent: MailHTMLView) {
            self.parent = parent
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == MailHTMLView.selectionHandler else { return }
            let text = message.body as? String ?? ""
            DispatchQueue.main.async { [weak self] in self?.parent.onSelection?(text) }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            measure(webView)
            // A freshly loaded mail has nothing selected.
            if let report = parent.onSelection { DispatchQueue.main.async { report("") } }
        }

        /// Height of the mail at the current text size (CSS height × zoom).
        func measure(_ webView: WKWebView) {
            guard let report = parent.onHeight else { return }
            let zoom = webView.pageZoom
            // App-side script (page scripts stay disabled).
            webView.evaluateJavaScript("Math.max(document.body.scrollHeight, document.documentElement.scrollHeight)") { value, _ in
                if let h = value as? Double { DispatchQueue.main.async { report(CGFloat(h) * zoom) } }
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { return decisionHandler(.cancel) }
            if action.navigationType == .other && (url.scheme == "about" || url.scheme == "data") {
                return decisionHandler(.allow)
            }
            if action.navigationType == .linkActivated {
                if url.scheme?.lowercased() == "mailto" {
                    parent.onMailto(url)
                } else if ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                    openExternally(url)
                }
                return decisionHandler(.cancel)
            }
            decisionHandler(url.scheme == "about" ? .allow : .cancel)
        }
    }
}

/// Forwards script messages to a delegate it does not keep alive
/// (WKUserContentController holds its handlers strongly).
final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?

    init(_ target: WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

/// Jitsi Meet call in a web view: JavaScript on, camera/microphone granted for the meeting host only.
struct JitsiWebView: PlatformViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator(host: url.host ?? "") }

    func makeWebView(_ context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        #if os(iOS)
        config.allowsInlineMediaPlayback = true
        #endif
        let web = WKWebView(frame: .zero, configuration: config)
        web.uiDelegate = context.coordinator
        web.navigationDelegate = context.coordinator
        web.customUserAgent = nil
        web.load(URLRequest(url: url))
        return web
    }

    #if os(macOS)
    func makeNSView(context: Context) -> WKWebView { makeWebView(context) }
    func updateNSView(_ web: WKWebView, context: Context) {}
    static func dismantleNSView(_ web: WKWebView, coordinator: Coordinator) { hangUp(web) }
    #else
    func makeUIView(context: Context) -> WKWebView { makeWebView(context) }
    func updateUIView(_ web: WKWebView, context: Context) {}
    static func dismantleUIView(_ web: WKWebView, coordinator: Coordinator) { hangUp(web) }
    #endif

    /// Leaves the conference and releases camera/mic when the view goes away.
    static func hangUp(_ web: WKWebView) {
        web.stopLoading()
        web.loadHTMLString("<html></html>", baseURL: nil)
    }

    final class Coordinator: NSObject, WKUIDelegate, WKNavigationDelegate {
        let host: String

        init(host: String) {
            self.host = host
        }

        func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
            decisionHandler(origin.host == host ? .grant : .deny)
        }

        // Links that open new windows (e.g. "Open in app", help) go to the system browser.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = navigationAction.request.url { openExternally(url) }
            return nil
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { return decisionHandler(.cancel) }
            // Stay on the meeting host; everything else opens outside.
            if url.host == host || url.scheme == "about" || url.scheme == "blob" || url.scheme == "data" {
                decisionHandler(.allow)
            } else if action.targetFrame?.isMainFrame == false {
                decisionHandler(.allow) // embedded frames (e.g. whiteboard) inside the meeting
            } else {
                openExternally(url)
                decisionHandler(.cancel)
            }
        }
    }
}

/// The mail's web view. On the Mac, when it is as tall as its mail (a message in a conversation), the scroll wheel
/// goes on to the page around it; a plain WKWebView keeps the wheel and the page wouldn't move under the pointer.
final class MailWebView: WKWebView {
    #if os(macOS)
    var passesScrollToPage = false

    override func scrollWheel(with event: NSEvent) {
        if passesScrollToPage, let next = nextResponder {
            next.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }
    #endif
}
