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
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        load(web, context: context)
        return web
    }

    #if os(macOS)
    func makeNSView(context: Context) -> WKWebView { makeWebView(context) }
    func updateNSView(_ web: WKWebView, context: Context) { load(web, context: context) }
    #else
    func makeUIView(context: Context) -> WKWebView { makeWebView(context) }
    func updateUIView(_ web: WKWebView, context: Context) { load(web, context: context) }
    #endif

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

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: MailHTMLView
        var loaded: String?

        init(_ parent: MailHTMLView) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            measure(webView)
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
