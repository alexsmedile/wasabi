import SwiftUI

/// Root view: a slim vertical sidebar of service icons on the left, the active
/// service's WebView filling the rest. M1 keeps every service's WebViewController
/// alive (keepRunning) so switching is instant and logins persist.
struct ContentView: View {
    private let services = Service.defaults
    @State private var activeID: String
    @State private var controllers: [String: WebViewController]

    init() {
        let defaults = Service.defaults
        _activeID = State(initialValue: defaults.first?.id ?? "")
        _controllers = State(initialValue: Dictionary(
            uniqueKeysWithValues: defaults.map { ($0.id, WebViewController(service: $0)) }
        ))
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            if let controller = controllers[activeID] {
                ServiceWebView(controller: controller)
                    .id(activeID)
            } else {
                Color(nsColor: .windowBackgroundColor)
            }
        }
    }

    private var sidebar: some View {
        VStack(spacing: 8) {
            ForEach(services) { service in
                Button {
                    activeID = service.id
                } label: {
                    Image(systemName: service.symbol)
                        .font(.system(size: 20, weight: .medium))
                        .frame(width: 44, height: 44)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(service.id == activeID
                                      ? Color.accentColor.opacity(0.22)
                                      : Color.clear)
                        )
                        .foregroundStyle(service.id == activeID ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .help(service.name)
            }

            // "+" add-service button — wired in post-M1; placeholder for now.
            Button {
                // TODO(post-M1): present AddServiceView
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .medium))
                    .frame(width: 44, height: 44)
                    .foregroundStyle(Color.secondary)
            }
            .buttonStyle(.plain)
            .help("Add service")
            .disabled(true)

            Spacer()
        }
        .padding(.vertical, 10)
        .frame(width: 60)
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}
