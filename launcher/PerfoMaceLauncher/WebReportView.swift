import SwiftUI
import WebKit

struct WebReportView: NSViewRepresentable {
    let url: URL?
    let reloadToken: Int

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.setValue(false, forKey: "drawsBackground")
        return view
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        guard let url else { return }
        if context.coordinator.lastReloadToken != reloadToken {
            nsView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            context.coordinator.lastReloadToken = reloadToken
            return
        }
        if nsView.url != url {
            nsView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            context.coordinator.lastReloadToken = reloadToken
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var lastReloadToken: Int = 0
    }
}
