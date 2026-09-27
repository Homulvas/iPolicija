import SwiftUI
import WebKit

/// Shows epolicija.lt while the app fills the report, and for login / final review.
struct ReportSheet: View {
    @ObservedObject var controller: EpolicijaController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            WebViewContainer(webView: controller.webView)
                .ignoresSafeArea(edges: .bottom)
                .overlay {
                    if controller.phase == .loading || controller.phase == .filling {
                        ZStack {
                            Rectangle().fill(.regularMaterial)
                            VStack(spacing: 12) {
                                ProgressView()
                                Text(controller.phase == .loading ? "Opening epolicija.lt…" : "Filling in the report…")
                                    .font(.headline)
                                Text("This takes a few seconds.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .ignoresSafeArea()
                    }
                }
                .safeAreaInset(edge: .top) { banner }
                .navigationTitle("epolicija.lt")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { dismiss() }
                    }
                }
        }
    }

    @ViewBuilder
    private var banner: some View {
        switch controller.phase {
        case .needsLogin:
            BannerView(
                icon: "person.badge.key",
                color: .blue,
                title: "Log in to epolicija",
                message: "Choose your bank and confirm with Smart-ID. The app clicks the rest and fills in the report once you're in."
            )
        case .ready(let notes):
            BannerView(
                icon: "checkmark.seal",
                color: .green,
                title: "Ready — review and send",
                message: (["Everything is filled in and the declarations are ticked. Read the summary below, then tap PATEIKTI to send."] + notes)
                    .joined(separator: "\n")
            )
        case .failed(let message):
            BannerView(
                icon: "exclamationmark.triangle",
                color: .orange,
                title: "Couldn't finish automatically",
                message: message + "\nYou can finish the form below yourself."
            )
        case .loading, .filling:
            EmptyView()
        }
    }
}

private struct BannerView: View {
    let icon: String
    let color: Color
    let title: String
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(message).font(.footnote)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(.bar)
    }
}

struct WebViewContainer: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
