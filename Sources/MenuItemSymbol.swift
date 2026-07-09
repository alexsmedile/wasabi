import AppKit

extension NSMenuItem {
    /// Attach an SF Symbol as the item's leading icon (matches the macOS system
    /// menus that show icons). No-op if `name` is nil or the symbol is unavailable,
    /// so a bad/renamed symbol degrades to a plain text item instead of crashing.
    @discardableResult
    func setSymbol(_ name: String?) -> NSMenuItem {
        if let name {
            image = NSImage(systemSymbolName: name, accessibilityDescription: title)
        }
        return self
    }
}
