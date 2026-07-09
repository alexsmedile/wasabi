import WebKit

/// A `WKWebView` that trims expensive native context-menu items.
///
/// **Drag-drop note (why there's no drag override here anymore).** By default,
/// dropping a file (PDF, image, …) on a `WKWebView` makes WebKit's own drag
/// destination *navigate to* the file URL and render it in-view — so a PDF
/// dropped on WhatsApp Web opened the PDF instead of attaching it. The earlier
/// fix stripped `.fileURL` from the view's registered drag types so the drop
/// "fell through" to the page's DOM handler. That was fragile: WebKit needs
/// those file types registered to populate `DataTransfer.files`, and it
/// re-registers them on every WebContent-process relaunch (now frequent, with
/// the shared process pool + sleep/wake). The strip raced those relaunches,
/// leaving a state where the drop overlay appeared but no file ever uploaded.
///
/// The drop is now handled the right way: file types stay registered (so the DOM
/// gets the file), and the *navigation* to a dropped `file://` URL is cancelled
/// deterministically in `WebViewController`'s `decidePolicyFor navigationAction`.
final class NonNavigatingWebView: WKWebView {
    /// WebKit's native image context menu lags badly on WhatsApp's full-screen
    /// media viewer: "Look Up", "Share…", and the Insert/AutoFill items force a
    /// synchronous extraction + Visual-Look-Up analysis of the full-resolution
    /// image on the main thread when the menu is built. We never use those items
    /// here, so strip them by their stable WebKit menu-item identifiers. WebKit
    /// only populates the expensive payloads for items it actually presents, so
    /// removing them up front avoids the work — the menu opens instantly and the
    /// useful items (Open in New Window, Download Image, Copy Image, Copy Link)
    /// remain. See FEEDBACKS.md / context-menu lag report.
    private static let expensiveMenuItemIdentifiers: Set<String> = [
        "WKMenuItemIdentifierLookUp",
        "WKMenuItemIdentifierTranslate",
        "WKMenuItemIdentifierShareMenu",
        // The "iFrames" debug submenu and the AutoFill / "Insert from iPhone"
        // (Continuity) entries are not exposed via stable identifiers; match
        // them by title as a fallback below.
    ]

    private static let expensiveMenuItemTitleFragments: [String] = [
        "iFrames",
        "AutoFill",
        "Insert from iPhone",
    ]

    /// A hidden (inactive) service must never be a drop target. Sibling WebViews
    /// stay mounted-but-hidden for instant switching, and each is a registered
    /// drag destination; when the visible one's WebKit drag registration is stale
    /// after a wake rebuild, AppKit's drag search can deliver the drop to a hidden
    /// sibling — the file silently uploads into the *wrong service*. Refuse every
    /// drag while hidden so only the visible WebView can accept a drop.
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        isHiddenOrHasHiddenAncestor ? [] : super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        isHiddenOrHasHiddenAncestor ? [] : super.draggingUpdated(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        !isHiddenOrHasHiddenAncestor && super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        !isHiddenOrHasHiddenAncestor && super.performDragOperation(sender)
    }

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        menu.items.removeAll { item in
            if let id = item.identifier?.rawValue,
               Self.expensiveMenuItemIdentifiers.contains(id) {
                return true
            }
            return Self.expensiveMenuItemTitleFragments.contains { fragment in
                item.title.localizedCaseInsensitiveContains(fragment)
            }
        }
        // Collapse any separators left dangling by the removals (leading,
        // trailing, or doubled) so the trimmed menu doesn't show empty gaps.
        collapseRedundantSeparators(in: menu)
        super.willOpenMenu(menu, with: event)
    }

    private func collapseRedundantSeparators(in menu: NSMenu) {
        var result: [NSMenuItem] = []
        for item in menu.items {
            if item.isSeparatorItem {
                if result.isEmpty || result.last?.isSeparatorItem == true { continue }
            }
            result.append(item)
        }
        while result.last?.isSeparatorItem == true { result.removeLast() }
        if result.count != menu.items.count {
            menu.removeAllItems()
            for item in result { menu.addItem(item) }
        }
    }
}
