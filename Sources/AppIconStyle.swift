import AppKit

/// User choice for the Dock / app-switcher icon.
///
/// - `.static`  — the bundled wasabi mark (`AppIcon.icns`). Default.
/// - `.dynamic` — a frosted squircle showing the favicons of the added services
///   in an adaptive grid, rebuilt as favicons resolve. See `AppIconRenderer`.
enum AppIconStyle: String {
    case `static`
    case dynamic

    static let `default`: AppIconStyle = .static
    private static let defaultsKey = "wasabi.appiconstyle"

    static var current: AppIconStyle {
        get {
            guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
                  let style = AppIconStyle(rawValue: raw) else { return .default }
            return style
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }
}

/// Applies the chosen app icon and keeps the dynamic one in sync with favicons.
///
/// `nil` icon image restores the bundled `AppIcon.icns` (static mode). For
/// dynamic mode it renders the current favicon set into one composite image.
@MainActor
final class AppIconController {
    /// Closure returning the current services' favicons in sidebar order.
    /// Entries may be `nil` while a favicon hasn't resolved yet.
    private let faviconsProvider: () -> [NSImage?]

    init(faviconsProvider: @escaping () -> [NSImage?]) {
        self.faviconsProvider = faviconsProvider
    }

    /// Re-apply the icon for the current style. Call on launch, on style change,
    /// and whenever a favicon resolves (dynamic mode only — cheap no-op otherwise).
    func refresh() {
        switch AppIconStyle.current {
        case .static:
            NSApp.applicationIconImage = nil          // restore bundled .icns
        case .dynamic:
            NSApp.applicationIconImage = AppIconRenderer.render(favicons: faviconsProvider())
        }
    }

    func setStyle(_ style: AppIconStyle) {
        AppIconStyle.current = style
        refresh()
    }
}
