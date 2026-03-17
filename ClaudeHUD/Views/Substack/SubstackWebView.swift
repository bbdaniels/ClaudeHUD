import SwiftUI
import WebKit

/// A WKWebView subclass that forwards scroll events to the parent scroll view.
class ScrollPassthroughWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) {
        // Forward all scroll events to the next responder (parent ScrollView)
        nextResponder?.scrollWheel(with: event)
    }
}

struct SubstackWebView: NSViewRepresentable {
    let html: String
    let fontScale: CGFloat
    @Binding var measuredHeight: CGFloat

    func makeNSView(context: Context) -> ScrollPassthroughWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "sizeChange")
        let webView = ScrollPassthroughWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 1), configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        context.coordinator.heightBinding = $measuredHeight
        loadContent(webView)
        return webView
    }

    func updateNSView(_ webView: ScrollPassthroughWebView, context: Context) {
        let prev = context.coordinator
        if prev.lastHTML != html || prev.lastFontScale != fontScale {
            prev.lastHTML = html
            prev.lastFontScale = fontScale
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
            a { color: #5ac8fa; text-decoration: none; }
            a:hover { text-decoration: underline; }
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
            function reportSize() {
                var wrapper = document.getElementById('content-wrapper');
                var h = Math.max(
                    wrapper ? wrapper.offsetHeight : 0,
                    document.body.scrollHeight,
                    document.documentElement.scrollHeight
                );
                if (h > 0 && h !== lastH) {
                    lastH = h;
                    window.webkit.messageHandlers.sizeChange.postMessage(String(h));
                }
            }
            reportSize();
            new ResizeObserver(reportSize).observe(document.body);
            // Report after images load
            document.querySelectorAll('img').forEach(function(img) {
                img.addEventListener('load', reportSize);
                img.addEventListener('error', function() { this.style.display = 'none'; reportSize(); });
            });
            // Safety net: re-measure after resources finish and with delays
            window.onload = reportSize;
            setTimeout(reportSize, 300);
            setTimeout(reportSize, 800);
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

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            if let str = message.body as? String, let h = Double(str), h > 0 {
                DispatchQueue.main.async { [weak self] in
                    self?.heightBinding?.wrappedValue = CGFloat(h)
                }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.evaluateJavaScript("Math.max(document.body.scrollHeight, document.documentElement.scrollHeight)") { [weak self] result, _ in
                if let h = result as? CGFloat, h > 0 {
                    DispatchQueue.main.async {
                        self?.heightBinding?.wrappedValue = h
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

    static func dismantleNSView(_ nsView: ScrollPassthroughWebView, coordinator: Coordinator) {
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: "sizeChange")
    }
}
