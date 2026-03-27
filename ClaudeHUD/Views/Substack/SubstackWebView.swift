import SwiftUI
import WebKit

/// WKWebView subclass — scrolls internally when content overflows the frame,
/// forwards to the parent scroll view only when content fits.
class ArticleWebView: WKWebView {
    private weak var parentScrollView: NSScrollView?
    private var isForwardingScroll = false
    private var lastForwardedTimestamp: TimeInterval = 0
    var contentFitsInFrame = true

    override func scrollWheel(with event: NSEvent) {
        if contentFitsInFrame {
            // Content fits — forward scroll to the outer feed list
            guard !isForwardingScroll,
                  event.timestamp != lastForwardedTimestamp else { return }
            if parentScrollView == nil {
                var view: NSView? = superview
                while let v = view {
                    if let sv = v as? NSScrollView {
                        parentScrollView = sv
                        break
                    }
                    view = v.superview
                }
            }
            if let sv = parentScrollView {
                lastForwardedTimestamp = event.timestamp
                isForwardingScroll = true
                sv.scrollWheel(with: event)
                isForwardingScroll = false
            }
        } else {
            // Content overflows — let the web view scroll internally
            super.scrollWheel(with: event)
        }
    }
}

struct SubstackWebView: NSViewRepresentable {
    let html: String
    let fontScale: CGFloat
    @Binding var measuredHeight: CGFloat

    func makeNSView(context: Context) -> ArticleWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "sizeChange")
        let webView = ArticleWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 1), configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        context.coordinator.heightBinding = $measuredHeight
        context.coordinator.webView = webView
        loadContent(webView)
        return webView
    }

    func updateNSView(_ webView: ArticleWebView, context: Context) {
        let prev = context.coordinator
        if prev.lastHTML != html || prev.lastFontScale != fontScale {
            prev.lastHTML = html
            prev.lastFontScale = fontScale
            prev.heightLocked = false
            loadContent(webView)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    private func loadContent(_ webView: WKWebView) {
        let fontSize = 11.5 * fontScale
        let doc = """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
            * { box-sizing: border-box; }
            body {
                font-family: "Fira Sans", -apple-system, BlinkMacSystemFont, sans-serif;
                font-size: \(fontSize)px;
                line-height: 1.55;
                color: rgba(255,255,255,0.85);
                background: transparent;
                margin: 0;
                padding: 0;
                word-wrap: break-word;
                overflow-wrap: break-word;
            }
            p { margin: 0.6em 0; }
            a {
                color: #000;
                text-decoration: none;
                background: #ffe600;
                padding: 1px 4px;
                border-radius: 4px;
            }
            a:hover { background: #ffd000; }
            img {
                max-width: 100%;
                height: auto;
                border-radius: 4px;
                margin: 0.5em 0;
                display: block;
            }
            h1, h2, h3, h4, h5, h6 {
                font-weight: 600;
                margin: 1em 0 0.4em;
                color: rgba(255,255,255,0.95);
            }
            h1 { font-size: 1.4em; }
            h2 { font-size: 1.25em; }
            h3 { font-size: 1.1em; }
            blockquote {
                border-left: 2px solid rgba(255,255,255,0.2);
                margin: 0.6em 0;
                padding: 0.2em 0 0.2em 1em;
                color: rgba(255,255,255,0.6);
            }
            ul, ol { padding-left: 1.5em; margin: 0.5em 0; }
            li { margin: 0.2em 0; }
            pre, code {
                font-family: "Fira Code", "SF Mono", Menlo, monospace;
                font-size: 0.9em;
                background: rgba(255,255,255,0.06);
                border-radius: 3px;
            }
            pre { padding: 0.6em; overflow-x: auto; }
            code { padding: 0.1em 0.3em; }
            pre code { padding: 0; background: none; }
            hr {
                border: none;
                border-top: 1px solid rgba(255,255,255,0.12);
                margin: 1em 0;
            }
            figure { margin: 0.8em 0; }
            figcaption {
                font-size: 0.85em;
                color: rgba(255,255,255,0.5);
                margin-top: 0.3em;
            }
            table {
                border-collapse: collapse;
                width: 100%;
                margin: 0.5em 0;
                font-size: 0.9em;
            }
            th, td {
                border: 1px solid rgba(255,255,255,0.12);
                padding: 0.4em 0.6em;
                text-align: left;
            }
            th { background: rgba(255,255,255,0.05); font-weight: 600; }
            .captioned-image-container { margin: 0.8em 0; }
            .image-link { display: block; }
            .subtitle { color: rgba(255,255,255,0.6); font-style: italic; }
            .footer { color: rgba(255,255,255,0.5); font-size: 0.85em; }
            /* Hide Substack-specific UI elements */
            .subscribe-widget, .subscription-widget-wrap,
            .button-wrapper, .share-dialog { display: none !important; }
        </style>
        </head>
        <body>
        <div id="content-wrapper">\(html)</div>
        <script>
            var lastH = 0;
            var debounceTimer = null;
            function reportSize() {
                var wrapper = document.getElementById('content-wrapper');
                var h = Math.max(
                    wrapper ? wrapper.offsetHeight : 0,
                    document.body.scrollHeight,
                    document.documentElement.scrollHeight
                );
                if (h > 0 && Math.abs(h - lastH) > 2) {
                    lastH = h;
                    window.webkit.messageHandlers.sizeChange.postMessage(String(h));
                }
            }
            // Debounced version — collapses rapid-fire image loads into one
            // height update so we don't thrash SwiftUI layout.
            function debouncedReportSize() {
                if (debounceTimer) clearTimeout(debounceTimer);
                debounceTimer = setTimeout(reportSize, 120);
            }
            reportSize();
            new ResizeObserver(debouncedReportSize).observe(document.body);
            // Lazy-load and async-decode images to avoid blocking the main thread
            document.querySelectorAll('img').forEach(function(img) {
                img.loading = 'lazy';
                img.decoding = 'async';
                img.addEventListener('load', debouncedReportSize);
                img.addEventListener('error', function() { this.style.display = 'none'; debouncedReportSize(); });
            });
            // Safety net: re-measure after resources finish and with delays
            window.onload = reportSize;
            setTimeout(reportSize, 500);
            setTimeout(reportSize, 2000);
        </script>
        </body>
        </html>
        """
        webView.loadHTMLString(doc, baseURL: URL(string: "https://substack.com"))
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var lastHTML = ""
        var lastFontScale: CGFloat = 0
        var heightBinding: Binding<CGFloat>?
        var heightLocked = false
        weak var webView: ArticleWebView?
        /// Max frame height — content taller than this scrolls inside the web view
        var maxFrameHeight: CGFloat = 500

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard !heightLocked else { return }
            if let str = message.body as? String, let h = Double(str), h > 0 {
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.heightLocked else { return }
                    self.heightBinding?.wrappedValue = CGFloat(h)
                    self.webView?.contentFitsInFrame = CGFloat(h) <= self.maxFrameHeight
                    // Lock after first real measurement to prevent layout churn
                    self.heightLocked = true
                }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !heightLocked else { return }
            webView.evaluateJavaScript("Math.max(document.body.scrollHeight, document.documentElement.scrollHeight)") { [weak self] result, _ in
                guard let self, !self.heightLocked else { return }
                if let h = result as? CGFloat, h > 0 {
                    DispatchQueue.main.async {
                        self.heightBinding?.wrappedValue = h
                        self.webView?.contentFitsInFrame = h <= self.maxFrameHeight
                        self.heightLocked = true
                    }
                }
            }
        }

        // Open links in default browser
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }
    }

    static func dismantleNSView(_ nsView: ArticleWebView, coordinator: Coordinator) {
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: "sizeChange")
    }
}
