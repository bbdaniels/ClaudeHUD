import SwiftUI
import WebKit

struct SubstackWebView: NSViewRepresentable {
    let html: String
    let fontScale: CGFloat

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        loadContent(webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
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
                padding: 0 26px 10px 26px;
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
            .subscribe-widget, .subscription-widget-wrap,
            .button-wrapper, .share-dialog { display: none !important; }
        </style>
        </head>
        <body>\(html)</body>
        </html>
        """
        webView.loadHTMLString(doc, baseURL: URL(string: "https://substack.com"))
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        var lastHTML = ""
        var lastFontScale: CGFloat = 0

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
}
