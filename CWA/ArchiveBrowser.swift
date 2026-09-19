import SwiftUI
import WebKit
import SafariServices

struct ArchiveBrowser: View {
    let client: Catalog
    @Environment(\.dismiss) private var dismiss
    @StateObject private var browser = ArchiveBrowserModel()
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if browser.loading { ProgressView().frame(maxWidth: .infinity).padding(6) }
                ArchiveWebView(browser: browser)
                if browser.downloading {
                    VStack(spacing: 8) {
                        ProgressView(value: browser.fraction)
                        HStack {
                            Text("Downloading EPUB…").font(.callout)
                            Spacer()
                            Button("Cancel") { browser.cancelDownload() }
                        }
                    }.padding().background(.regularMaterial)
                }
                if let error = browser.error {
                    HStack(alignment: .top) {
                        Text(error).font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Button("Dismiss", systemImage: "xmark") { browser.error = nil }.labelStyle(.iconOnly)
                    }.padding().background(.regularMaterial)
                }
            }
            .navigationTitle(browser.host).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("English EPUBs", systemImage: "line.3.horizontal.decrease") { browser.englishEPUBs() }
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button("Back", systemImage: "chevron.left") { browser.webView.goBack() }.disabled(!browser.canGoBack)
                    Button("Forward", systemImage: "chevron.right") { browser.webView.goForward() }.disabled(!browser.canGoForward)
                    Spacer()
                    Button("Home", systemImage: "house") { browser.home() }
                    Button("Reload", systemImage: "arrow.clockwise") { browser.webView.reload() }
                    Spacer()
                    Button("Open in Safari", systemImage: "safari") {
                        if let url = browser.webView.url { UIApplication.shared.open(url) }
                    }
                }
            }
            .sheet(item: $browser.ready, onDismiss: { browser.clearStagedFile() }) { file in
                ArchiveImportSheet(client: client, file: file.url)
            }
            .onDisappear { browser.cancelDownload() }
        }
    }
}

private struct ArchiveWebView: UIViewRepresentable {
    let browser: ArchiveBrowserModel
    func makeUIView(context: Context) -> WKWebView { browser.webView }
    func updateUIView(_ view: WKWebView, context: Context) { }
}

@MainActor
final class ArchiveBrowserModel: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    let webView: WKWebView
    @Published var loading = false
    @Published var host = "Anna’s Archive"
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var downloading = false
    @Published var fraction = 0.0
    @Published var error: String?
    @Published var ready: SharedBook?
    private var activeDownload: WKDownload?
    private var destination: URL?
    private var stagedFolder: URL?
    private var progressObservation: NSKeyValueObservation?
    override init() {
        let config = WKWebViewConfiguration()
        // WebKit owns this isolated browser session. No CWA cookies or credentials enter it.
        config.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        home()
    }
    func home() {
        webView.load(URLRequest(url: URL(string: "https://annas-archive.gl")!))
    }
    func englishEPUBs() {
        var components = URLComponents(string: "https://annas-archive.gl/search")!
        components.queryItems = [URLQueryItem(name: "lang", value: "en"), URLQueryItem(name: "ext", value: "epub")]
        webView.load(URLRequest(url: components.url!))
    }
    private func updateNavigation() {
        host = webView.url?.host ?? "Anna’s Archive"
        canGoBack = webView.canGoBack; canGoForward = webView.canGoForward
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { loading = true; error = nil }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loading = false; updateNavigation() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { navigationFailed(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { navigationFailed(error) }
    private func navigationFailed(_ failure: Error) {
        loading = false; updateNavigation()
        if (failure as NSError).code != NSURLErrorCancelled {
            error = "This page could not load. Try Reload or open it in Safari, then use From Files to import your download."
        }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url, ["https", "http", "about", "blob"].contains(url.scheme?.lowercased() ?? "") else {
            decisionHandler(.cancel); return
        }
        if navigationAction.shouldPerformDownload {
            decisionHandler(downloading || ready != nil ? .cancel : .download)
        } else { decisionHandler(.allow) }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let response = navigationResponse.response
        let isBook = response.mimeType?.lowercased() == "application/epub+zip" || response.suggestedFilename?.lowercased().hasSuffix(".epub") == true
        if isBook || !navigationResponse.canShowMIMEType {
            if downloading || ready != nil { decisionHandler(.cancel); return }
            if response.expectedContentLength > 200 * 1024 * 1024 {
                error = "Choose an EPUB smaller than 200 MB."; decisionHandler(.cancel); return
            }
            decisionHandler(.download)
        } else { decisionHandler(.allow) }
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { start(download) }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { start(download) }
    private func start(_ download: WKDownload) {
        guard activeDownload == nil, ready == nil else { download.cancel { _ in }; return }
        activeDownload = download; downloading = true; fraction = 0; loading = false; error = nil
        download.delegate = self
        progressObservation = download.progress.observe(\.fractionCompleted, options: [.initial, .new]) { [weak self] progress, _ in
            let fraction = progress.fractionCompleted
            let completed = progress.completedUnitCount
            Task { @MainActor [weak self] in
                guard let self, self.downloading else { return }
                self.fraction = fraction
                if completed > 200 * 1024 * 1024 { self.cancelDownload(); self.error = "Choose an EPUB smaller than 200 MB." }
            }
        }
    }
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        guard activeDownload === download else { completionHandler(nil); return }
        do {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CWA-Archive-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            stagedFolder = folder
            let leaf = (suggestedFilename as NSString).lastPathComponent
            let safe = String(leaf.map { "/\\:?%*|\"<>".contains($0) || $0.isNewline ? "_" : $0 }.prefix(160))
            let name = safe.isEmpty ? "Book.epub" : (safe.lowercased().hasSuffix(".epub") ? safe : safe + ".epub")
            let file = folder.appendingPathComponent(name)
            destination = file; completionHandler(file)
        } catch { self.error = error.localizedDescription; completionHandler(nil) }
    }
    func downloadDidFinish(_ download: WKDownload) {
        guard activeDownload === download else { return }
        downloading = false; activeDownload = nil; progressObservation = nil
        do {
            guard let file = destination else { throw CatalogError.message("No downloaded file was received.") }
            try EPUBImport.validate(file)
            ready = SharedBook(url: file)
        } catch { self.error = error.localizedDescription; clearStagedFile() }
    }
    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard activeDownload === download else { return }
        downloading = false; activeDownload = nil; progressObservation = nil
        self.error = "The download did not finish. Try again on the website, or download in Safari and use From Files."
        clearStagedFile()
    }
    func cancelDownload() {
        progressObservation = nil
        let download = activeDownload
        activeDownload = nil; downloading = false
        let folder = ready == nil ? stagedFolder : nil
        if ready == nil { destination = nil; stagedFolder = nil }
        download?.cancel { _ in if let folder { try? FileManager.default.removeItem(at: folder) } }
        if download == nil, let folder { try? FileManager.default.removeItem(at: folder) }
    }
    func clearStagedFile() {
        if let stagedFolder { try? FileManager.default.removeItem(at: stagedFolder) }
        stagedFolder = nil; destination = nil
    }
}

private struct ArchiveImportSheet: View {
    let client: Catalog
    let file: URL
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false
    @State private var sent = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            VStack(spacing: 22) {
                Image(systemName: sent ? "checkmark.circle.fill" : "book.closed.fill")
                    .font(.system(size: 48)).foregroundStyle(Color.accentColor)
                Text(sent ? "Sent to CWA" : "Add to library?").font(.title2.bold())
                Text(file.lastPathComponent).font(.body).multilineTextAlignment(.center).lineLimit(4)
                if sent {
                    Text("Your book is queued for processing. Refresh your library after CWA finishes importing it.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Done") { dismiss() }.buttonStyle(.borderedProminent)
                } else {
                    if let error { Text(error).font(.callout).foregroundStyle(.red) }
                    Button { Task { await upload() } } label: {
                        HStack { if busy { ProgressView() }; Text(busy ? "Uploading…" : "Add to CWA") }.frame(maxWidth: .infinity)
                    }.buttonStyle(.borderedProminent).controlSize(.large).disabled(busy)
                    Button("Cancel", role: .cancel) { dismiss() }.disabled(busy)
                }
            }.padding(28).frame(maxWidth: .infinity)
            .interactiveDismissDisabled(busy)
        }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }
    @MainActor private func upload() async {
        guard !busy, !sent else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            try await client.uploadBook(file: file)
            client.invalidateBrowsing()
            NotificationCenter.default.post(name: .cwaBookChanged, object: nil)
            sent = true
        } catch { self.error = error.localizedDescription }
    }
}
