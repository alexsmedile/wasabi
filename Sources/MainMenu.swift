import AppKit

/// Builds the app's main menu programmatically.
///
/// A pure-AppKit app (no nib/storyboard) starts with `NSApp.mainMenu == nil`,
/// which means the standard editing shortcuts — ⌘C/⌘V/⌘X/⌘A — have nowhere to
/// dispatch and are silently swallowed. Those shortcuts live on the **Edit menu**:
/// each item carries a key equivalent and a standard first-responder selector
/// (`copy:`, `paste:`, …) that travels down the responder chain to the focused
/// WKWebView. So the menu *is* the keyboard wiring — without it, only WebKit's
/// own right-click context menu can copy/paste.
@MainActor
enum MainMenu {
    static func build() -> NSMenu {
        let mainMenu = NSMenu()

        mainMenu.addItem(appMenuItem())
        mainMenu.addItem(editMenuItem())
        mainMenu.addItem(viewMenuItem())

        return mainMenu
    }

    // MARK: - View menu (app icon style)

    private static func viewMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "View")

        // Reload the active service (⌘R). Target nil → dispatches up the responder
        // chain to MainViewController. No browser chrome, so this is the only
        // in-place refresh for a stuck web app.
        let reload = NSMenuItem(title: "Reload",
                                action: #selector(MainViewController.reloadActiveService(_:)),
                                keyEquivalent: "r")
        reload.setSymbol("arrow.clockwise")
        menu.addItem(reload)
        menu.addItem(.separator())

        let iconParent = NSMenuItem(title: "App Icon", action: nil, keyEquivalent: "")
        iconParent.setSymbol("app.badge")
        let iconMenu = NSMenu(title: "App Icon")
        iconMenu.autoenablesItems = false

        // Targets are nil → the action dispatches up the responder chain to the
        // MainViewController, which owns the AppIconController.
        let current = AppIconStyle.current
        let staticItem = NSMenuItem(title: "Static (Wasabi)", action: #selector(MainViewController.selectIconStyle(_:)), keyEquivalent: "")
        staticItem.tag = 0
        staticItem.state = (current == .static) ? .on : .off

        let dynamicItem = NSMenuItem(title: "Dynamic (Site favicons)", action: #selector(MainViewController.selectIconStyle(_:)), keyEquivalent: "")
        dynamicItem.tag = 1
        dynamicItem.state = (current == .dynamic) ? .on : .off

        iconMenu.addItem(staticItem)
        iconMenu.addItem(dynamicItem)
        iconParent.submenu = iconMenu
        menu.addItem(iconParent)

        menu.addItem(sidebarSizeItem())

        menu.addItem(.separator())
        let resetSize = NSMenuItem(title: "Reset Window Size",
                                   action: #selector(MainViewController.resetWindowSize(_:)),
                                   keyEquivalent: "")
        resetSize.setSymbol("arrow.counterclockwise")
        menu.addItem(resetSize)

        item.submenu = menu
        return item
    }

    // MARK: - View ▸ Sidebar Size (wide / medium / compact)

    private static func sidebarSizeItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "Sidebar Size", action: nil, keyEquivalent: "")
        parent.setSymbol("sidebar.left")
        let sub = NSMenu(title: "Sidebar Size")
        sub.autoenablesItems = false

        // Tags match MainViewController.sidebarSizeForTag: 0 wide / 1 medium / 2 compact.
        let current = MainViewController.SidebarSize.current
        let rows: [(String, Int, MainViewController.SidebarSize)] = [
            ("Wide", 0, .wide), ("Medium", 1, .medium), ("Compact", 2, .compact),
        ]
        for (title, tag, size) in rows {
            let mi = NSMenuItem(title: title,
                                action: #selector(MainViewController.selectSidebarSize(_:)),
                                keyEquivalent: "")
            mi.tag = tag
            mi.state = (current == size) ? .on : .off
            sub.addItem(mi)
        }

        parent.submenu = sub
        return parent
    }

    // MARK: - App menu (Quit lives here)

    /// Tag on the License menu item so the delegate can find + relabel it on open.
    static let licenseItemTag = 900

    private static func appMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu()
        // The License item's title reflects live tier (Pro ✓ / Trial: N days / Activate),
        // refreshed each time the menu opens — see AppDelegate.menuNeedsUpdate.
        menu.delegate = NSApp.delegate as? NSMenuDelegate
        let appName = ProcessInfo.processInfo.processName

        menu.addItem(withTitle: "Hide \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
            .setSymbol("eye.slash")

        let hideOthers = NSMenuItem(title: "Hide Others",
                                    action: #selector(NSApplication.hideOtherApplications(_:)),
                                    keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        hideOthers.setSymbol("eye.slash.fill")
        menu.addItem(hideOthers)

        menu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
            .setSymbol("eye")
        menu.addItem(.separator())
        // Targets UpdateChecker directly (a plain @objc method); no responder
        // chain needed since it's an app-global action.
        let checkUpdates = NSMenuItem(title: "Check for Updates…",
                                      action: #selector(UpdateChecker.checkForUpdatesFromMenu),
                                      keyEquivalent: "")
        checkUpdates.target = UpdateChecker.shared
        checkUpdates.setSymbol("arrow.triangle.2.circlepath")
        menu.addItem(checkUpdates)

        // License… — the activation window, reachable any time (not just at a gate).
        // Title is a placeholder; menuNeedsUpdate relabels it to live status on open.
        let license = NSMenuItem(title: "License…",
                                 action: #selector(AppDelegate.showLicenseWindow),
                                 keyEquivalent: "")
        license.target = NSApp.delegate
        license.tag = licenseItemTag
        license.setSymbol("key")
        menu.addItem(license)

        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            .setSymbol("power")

        item.submenu = menu
        return item
    }

    // MARK: - Edit menu (the copy/paste wiring)

    private static func editMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Edit")

        menu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
            .setSymbol("arrow.uturn.backward")

        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        redo.setSymbol("arrow.uturn.forward")
        menu.addItem(redo)

        menu.addItem(.separator())
        menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
            .setSymbol("scissors")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
            .setSymbol("doc.on.doc")
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
            .setSymbol("doc.on.clipboard")
        menu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
            .setSymbol("selection.pin.in.out")

        item.submenu = menu
        return item
    }
}
