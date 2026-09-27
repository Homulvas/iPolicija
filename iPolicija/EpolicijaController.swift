import Foundation
import UIKit
import WebKit

/// Runs epolicija.lt inside the app: keeps the login (persistent cookies), injects
/// `epolicija-driver.js`, fills the report and stops at the declarations for the person to submit.
@MainActor
final class EpolicijaController: NSObject, ObservableObject, WKNavigationDelegate {
    enum Phase: Equatable {
        case loading
        case needsLogin
        case filling
        case ready(notes: [String])
        case failed(String)
    }

    @Published private(set) var phase: Phase = .loading
    let webView: WKWebView

    private var payload: [String: Any] = [:]
    private var hasRunFill = false
    private var loginStarted = false
    private let driverLoaded: Bool

    static let formURL = URL(string: "https://www.epolicija.lt/forms/report/4003/authenticated/")!
    static let loginURL = URL(string: "https://www.epolicija.lt/report")!

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()   // keeps the epolicija login between reports
        var loaded = false
        if let url = Bundle.main.url(forResource: "epolicija-driver", withExtension: "js"),
           let js = try? String(contentsOf: url, encoding: .utf8) {
            config.userContentController.addUserScript(
                WKUserScript(source: js, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
            )
            loaded = true
        }
        driverLoaded = loaded
        // Phone-sized frame from the start so the page lays out before the sheet shows it.
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
        super.init()
        webView.navigationDelegate = self
        #if DEBUG
        webView.isInspectable = true   // Safari → Develop → iPhone, for debugging
        #endif
    }

    /// Start a report: open the form, log in if needed, then fill it.
    func start(payload: [String: Any]) {
        self.payload = payload
        hasRunFill = false
        loginStarted = false
        guard driverLoaded else {
            phase = .failed("The form-filling script is missing from the app.")
            return
        }
        phase = .loading
        webView.load(URLRequest(url: Self.formURL))
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in self.pageLoaded() }
    }

    private func pageLoaded() {
        guard let url = webView.url, !hasRunFill else { return }
        let host = url.host ?? ""

        if host.hasSuffix("epolicija.lt"), url.path.hasPrefix("/forms/report/4003/authenticated") {
            hasRunFill = true
            Task { await fill() }
            return
        }

        if host.hasSuffix("epolicija.lt"), phase == .loading {
            // Opening the form redirected elsewhere: not logged in.
            phase = .needsLogin
            if url.path != "/report" {
                webView.load(URLRequest(url: Self.loginURL))
                return
            }
        }

        guard phase == .needsLogin else { return }

        if host.hasSuffix("epolicija.lt"), url.path == "/report", !loginStarted {
            // Pick the traffic report type and "Prisijungti per e. valdžios vartus".
            loginStarted = true
            Task { _ = try? await webView.callAsyncJavaScript(
                "return await window.__ipLogin.startEpolicijaLogin();", arguments: [:], contentWorld: .page) }
        } else if host == "seb.lt" || host.hasSuffix(".seb.lt") {
            // SEB: after Smart-ID, agree to pass data to the gateway ("Sutinku").
            Task { _ = try? await webView.callAsyncJavaScript(
                "return await window.__ipLogin.confirmSebConsent();", arguments: [:], contentWorld: .page) }
        } else if host.hasSuffix("epaslaugos.lt") {
            // After the bank: the gateway's "Asmens duomenų perdavimas" page — click "Prisijungti".
            Task { _ = try? await webView.callAsyncJavaScript(
                "return await window.__ipLogin.confirmDataTransfer();", arguments: [:], contentWorld: .page) }
        }
        // Bank pages: the person logs in and confirms Smart-ID; the form loads afterwards.
    }

    private func fill() async {
        phase = .filling
        do {
            // Wait for ZK to render the form and for the driver to be present.
            var ready = false
            for _ in 0..<75 {
                // Ready = driver loaded and step 1 actually visible (not just present in the DOM).
                let check = try? await webView.evaluateJavaScript(
                    "!!(window.__ip && window.zk && window.__ip.exists('Kaip Jūs susiję su įvykiu?'))"
                )
                if (check as? Bool) == true { ready = true; break }
                try await Task.sleep(nanoseconds: 200_000_000)
            }
            guard ready else {
                phase = .failed("The epolicija form didn't finish loading.")
                return
            }

            let result = try await webView.callAsyncJavaScript(
                "return await window.__ip.fillReport(data);",
                arguments: ["data": payload],
                contentWorld: .page
            )
            let dict = result as? [String: Any] ?? [:]
            let notes = dict["notes"] as? [String] ?? []
            if dict["ok"] as? Bool == true {
                let declarations = dict["declarations"] as? [String] ?? []
                phase = .ready(notes: notes + (declarations.isEmpty ? [] : ["Declarations ticked: \(declarations.count)"]))
            } else if await reviewPageShown() {
                phase = .ready(notes: notes)
            } else {
                let step = dict["step"] as? String ?? "?"
                let error = dict["error"] as? String ?? "Unknown error"
                phase = .failed("Stopped at \"\(step)\": \(error)")
            }
        } catch {
            // Opening the summary may load a new page, which cuts the script off mid-run.
            if await reviewPageShown() {
                phase = .ready(notes: [])
            } else {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    /// True when the summary page with the "Pateikti policijai" button is on screen.
    private func reviewPageShown() async -> Bool {
        let js = "[...document.querySelectorAll('button')].some(b => b.offsetParent && /^pateikti policijai$/i.test(b.textContent.replace(/\\s+/g, ' ').trim()))"
        for _ in 0..<25 {
            if let shown = try? await webView.evaluateJavaScript(js) as? Bool, shown { return true }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return false
    }
}

extension ReportData {
    /// Data for `__ip.fillReport` in epolicija-driver.js.
    func formPayload(photo: UIImage?) -> [String: Any] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"

        var photos: [[String: String]] = []
        if let photo, let jpeg = photo.jpegForUpload() {
            photos.append([
                "name": "iPolicija-\(plate.isEmpty ? "photo" : plate)-1.jpg",
                "type": "image/jpeg",
                "base64": jpeg.base64EncodedString()
            ])
        }

        return [
            "whatHappened": offence.formOption,
            "placeType": offence.placeType,
            "city": city,
            "street": street,
            "streetSearch": AddressResolver.streetSearchText(for: street),
            "house": house,
            "extraPlace": "",
            "dateTime": formatter.string(from: date),
            "plate": plate,
            "vehicle": "",
            "description": descriptionText,
            "hasVideo": false,   // photos only for now
            "photos": photos
        ]
    }
}

extension UIImage {
    /// JPEG no larger than 2048 px on the long side (the form allows 30 MB in total).
    func jpegForUpload(maxSide: CGFloat = 2048, quality: CGFloat = 0.8) -> Data? {
        let longest = max(size.width, size.height)
        let scale = longest > maxSide ? maxSide / longest : 1
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: target))   // also bakes in the orientation
        }
        return resized.jpegData(compressionQuality: quality)
    }
}
