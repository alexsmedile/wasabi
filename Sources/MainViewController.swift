import AppKit
import WebKit

/// Root view controller: a slim vertical sidebar of service icons on the left,
/// the active service's WKWebView filling the rest.
///
/// Per-service sleep is owned by `WebViewPool`: the active service stays live;
/// inactive ones are torn down per their `SleepPolicy` (keep running / timer /
/// smart) to reclaim their WebContent RAM. Right-click an icon to change policy.
final class MainViewController: NSViewController, NSMenuDelegate {
    private let registry = ServiceRegistry.shared
    /// Snapshot of the registry's ordered list, refreshed on each reload. The
    /// registry is the source of truth; this mirrors it for ordered iteration.
    private var services: [Service] = []
    private var controllers: [String: WebViewController] = [:]
    private var activeID: String = ""
    private var pool: WebViewPool!
    private var appIcon: AppIconController!

    private let sidebar = DraggableStackView()
    private let contentContainer = NSView()
    private let dragStrip = WindowDragStrip()
    private var sidebarButtons: [String: NSButton] = [:]
    private weak var addButton: NSButton?
    private var addSheet: AddServiceSheet?

    /// Stored geometry constraints, mutated (not rebuilt) on a size-mode change.
    private var sidebarWidthConstraint: NSLayoutConstraint!
    /// Each button's width+height constraints, keyed by the button, so `applySize`
    /// can resize tiles in place without tearing down the sidebar.
    private var buttonSizeConstraints: [(NSLayoutConstraint, NSLayoutConstraint)] = []

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1100, height: 760))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        view = root

        // The persisted registry is the source of truth for the service list
        // (seeded from Service.defaults on first launch). Build one controller per
        // service; the pool governs their lifecycle.
        services = registry.all()
        for service in services {
            controllers[service.id] = WebViewController(service: service)
        }
        pool = WebViewPool(controllers: controllers)
        // Repaint status dots when a service sleeps/wakes on its own (smart-sleep
        // timers, autosleep) — transitions the UI can't otherwise observe.
        pool.onLiveStateChanged = { [weak self] in
            self?.pruneSleptWebViews()
            self?.updateSelectionHighlight()
        }
        activeID = services.first?.id ?? ""

        // Re-sync the sidebar/pool when the registry changes (add/remove/reorder/
        // rename). Full delta handling lands in M2–M4; M1 just refreshes the
        // snapshot so the source of truth and the mirror stay in step.
        registry.onChange = { [weak self] in self?.reloadServices() }

        setupSidebar()
        setupContentContainer()
        layout()

        // The dynamic Dock icon is built from the services' favicons, in order.
        appIcon = AppIconController(faviconsProvider: { [weak self] in
            guard let self else { return [] }
            return self.services.map { FaviconProvider.shared.cachedIcon(for: $0.id) }
        })
        appIcon.refresh()

        // Swap in real favicons as they resolve from each service's WebView, and
        // keep the dynamic Dock icon in sync as new favicons arrive.
        FaviconProvider.shared.onResolved = { [weak self] serviceID, image in
            self?.applyFavicon(image, to: serviceID)
            // The Dock icon only depends on favicons in *dynamic* mode; in static
            // mode rebuilding it is pure waste. And favicons resolve in a burst at
            // startup — coalesce so we render the 1024² squircle once, not per icon.
            self?.scheduleDynamicIconRefresh()
        }

        // Clicking a macOS notification reselects the service it came from.
        NotificationManager.shared.onActivateService = { [weak self] serviceID in
            self?.select(serviceID: serviceID)
        }

        if !activeID.isEmpty { select(serviceID: activeID) }
    }

    /// The window exists by now (not during `loadView`), so apply the size mode's
    /// window layout — Layout B's full-size-content + titlebar inset needs the window.
    override func viewDidAppear() {
        super.viewDidAppear()
        applyWindowLayout(for: SidebarSize.current)

        // Fullscreen removes the titlebar (titlebar height → 0) and restores it on
        // exit; recompute the sidebar top inset on each transition so the first icon
        // never overlaps or gaps from the lights. Idempotent if already observed.
        guard let window = view.window, !registeredFullScreenObservers else { return }
        registeredFullScreenObservers = true
        let nc = NotificationCenter.default
        for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            nc.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                self?.updateSidebarTopInset()
            }
        }
    }
    private var registeredFullScreenObservers = false

    // MARK: - App icon style (static wasabi vs dynamic favicon grid)

    @objc func selectIconStyle(_ sender: NSMenuItem) {
        let style: AppIconStyle = (sender.tag == 1) ? .dynamic : .static
        appIcon.setStyle(style)
        sender.menu?.items.forEach { $0.state = ($0.tag == sender.tag) ? .on : .off }
    }

    // MARK: - Window size

    /// The app's default window size — the one it launches at. Shared with
    /// `AppDelegate` (creation) and View ▸ Reset Window Size (restore).
    static let defaultWindowSize = NSSize(width: 1200, height: 760)

    @objc func resetWindowSize(_ sender: Any?) {
        guard let window = view.window else { return }
        if window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
        window.setContentSize(Self.defaultWindowSize)
        window.center()
    }

    // MARK: - Sidebar size (View ▸ Sidebar Size)

    /// Menu tags map to sizes: 0 wide / 1 medium / 2 compact.
    private static let sidebarSizeForTag: [Int: SidebarSize] = [0: .wide, 1: .medium, 2: .compact]

    @objc func selectSidebarSize(_ sender: NSMenuItem) {
        guard let size = Self.sidebarSizeForTag[sender.tag] else { return }
        SidebarSize.current = size
        applySize(size)
        sender.menu?.items.forEach { $0.state = ($0.tag == sender.tag) ? .on : .off }
    }

    /// Apply a size mode to the live sidebar by mutating stored constraints — no
    /// teardown, so WebViews and their sessions are untouched. Animated unless the
    /// user prefers reduced motion. (Window-layout switch arrives in a later milestone.)
    private func applySize(_ size: SidebarSize) {
        sidebar.spacing = size.gap
        sidebarWidthConstraint.constant = size.sidebarWidth
        applyWindowLayout(for: size)   // owns edgeInsets (titlebar inset differs per layout)
        for (w, h) in buttonSizeConstraints { w.constant = size.tile; h.constant = size.tile }
        // Redraw each icon at the new size: a resolved favicon re-clips to the new
        // side; otherwise the SF-Symbol placeholder is rebuilt at the new pointSize.
        let symbolByID = Dictionary(services.map { ($0.id, $0.symbol) }, uniquingKeysWith: { a, _ in a })
        for (id, button) in sidebarButtons {
            if let cached = FaviconProvider.shared.cachedIcon(for: id) {
                applyFavicon(cached, to: id)
            } else if let symbol = symbolByID[id] {
                button.image = symbolImage(symbol, size: size.icon)
            }
        }
        // The "+" glyph isn't a service, so rescale it separately.
        addButton?.image = symbolImage("plus", size: size.icon)

        // Re-assert the active ring at the new tile size.
        updateSelectionHighlight()

        let apply = { self.view.layoutSubtreeIfNeeded() }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            apply()
        } else {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                ctx.allowsImplicitAnimation = true
                apply()
            }
        }
    }

    /// Coalesce dynamic-icon refreshes. Favicons resolve in a startup burst (and
    /// again on smart-sleep wakes); rendering the full 1024² squircle per resolve
    /// is wasted work. Debounce to one render per runloop turn, and skip entirely
    /// in static mode where the Dock icon doesn't depend on favicons.
    private var dynamicIconRefreshScheduled = false
    private func scheduleDynamicIconRefresh() {
        guard AppIconStyle.current == .dynamic, !dynamicIconRefreshScheduled else { return }
        dynamicIconRefreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.dynamicIconRefreshScheduled = false
            self.appIcon.refresh()
        }
    }

    /// Sidebar geometry, selectable in three sizes (View ▸ Sidebar Size). Points,
    /// not pixels — Retina/display scaling is handled by AppKit. Medium is the
    /// shipped default and matches the original slim rail; wide ≈ a Finder/Notes
    /// source list; compact is −25%. `current` persists across launches.
    enum SidebarSize: String {
        case wide, medium, compact

        /// Width of the sidebar rail. Wide is 72 so the window's own traffic-light
        /// cluster (~54pt) sits centered with ~9pt gutters in Layout B (later milestone).
        var sidebarWidth: CGFloat { switch self { case .wide: 72; case .medium: 48; case .compact: 40 } }
        /// The square service tile (the app-icon frame).
        var tile: CGFloat { switch self { case .wide: 48; case .medium: 36; case .compact: 28 } }
        /// The favicon/SF-Symbol drawn inside the tile.
        var icon: CGFloat { switch self { case .wide: 30; case .medium: 22; case .compact: 16 } }
        /// Vertical gap between tiles.
        var gap: CGFloat { switch self { case .wide: 14; case .medium: 8; case .compact: 6 } }
        /// Top/bottom padding of the rail — scales with the mode's rhythm.
        var edgeInset: CGFloat { switch self { case .wide: 14; case .medium: 12; case .compact: 10 } }

        private static let key = "wasabi.sidebar.size"
        static var current: SidebarSize {
            get { (UserDefaults.standard.string(forKey: key)).flatMap(SidebarSize.init) ?? .medium }
            set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
        }
    }

    // MARK: - Sidebar

    private func setupSidebar() {
        sidebar.orientation = .vertical
        sidebar.alignment = .centerX
        sidebar.spacing = SidebarSize.current.gap
        let inset = SidebarSize.current.edgeInset
        sidebar.edgeInsets = NSEdgeInsets(top: inset, left: 0, bottom: inset, right: 0)
        sidebar.translatesAutoresizingMaskIntoConstraints = false

        let bg = NSVisualEffectView()
        bg.material = .sidebar
        bg.blendingMode = .behindWindow
        bg.state = .active
        bg.translatesAutoresizingMaskIntoConstraints = false

        for service in services {
            let button = makeServiceButton(for: service)
            sidebar.addArrangedSubview(button)
        }

        // "+" add-service button. Always the last arranged subview, so new
        // service buttons insert just before it.
        let addButton = makeIconButton(symbol: "plus", tooltip: "Add service")
        addButton.target = self
        addButton.action = #selector(addServiceTapped)
        sidebar.addArrangedSubview(addButton)
        self.addButton = addButton

        bg.addSubview(sidebar)
        NSLayoutConstraint.activate([
            sidebar.topAnchor.constraint(equalTo: bg.topAnchor),
            sidebar.bottomAnchor.constraint(lessThanOrEqualTo: bg.bottomAnchor),
            sidebar.leadingAnchor.constraint(equalTo: bg.leadingAnchor),
            sidebar.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
        ])

        sidebarBG = bg
    }

    private var sidebarBG: NSVisualEffectView!

    /// Build a fully-wired sidebar button for a service (icon, action, right-click
    /// menu, cached favicon) and register it in `sidebarButtons`. Shared by the
    /// initial build and the runtime add-delta so both stay identical.
    private func makeServiceButton(for service: Service) -> NSButton {
        let button = makeIconButton(symbol: service.symbol, tooltip: service.name)
        button.target = self
        button.action = #selector(serviceButtonTapped(_:))
        button.identifier = NSUserInterfaceItemIdentifier(service.id)
        button.menu = makeServiceMenu(for: service.id)   // right-click → back / sleep policy
        let pan = NSPanGestureRecognizer(target: self, action: #selector(handleReorderPan(_:)))
        button.addGestureRecognizer(pan)
        sidebarButtons[service.id] = button
        button.wantsLayer = true     // for the active-service ring (set in updateSelectionHighlight)
        // Show a previously cached favicon immediately; the live one refreshes it
        // once the service loads.
        if let cached = FaviconProvider.shared.cachedIcon(for: service.id) {
            applyFavicon(cached, to: service.id)
        }
        return button
    }

    /// An SF Symbol image at the given point size — the one place symbol icons are
    /// rendered, so `makeIconButton`, the resize loop, and the "+" all stay in step.
    private func symbolImage(_ symbol: String, size: CGFloat) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: .medium)
        return NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
    }

    private func makeIconButton(symbol: String, tooltip: String) -> NSButton {
        let size = SidebarSize.current
        let button = NSButton()
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.toolTip = tooltip
        button.image = symbolImage(symbol, size: size.icon)
        button.translatesAutoresizingMaskIntoConstraints = false
        let w = button.widthAnchor.constraint(equalToConstant: size.tile)
        let h = button.heightAnchor.constraint(equalToConstant: size.tile)
        NSLayoutConstraint.activate([w, h])
        buttonSizeConstraints.append((w, h))
        return button
    }

    /// Replace a service button's SF Symbol with its resolved favicon, scaled to
    /// the icon size with rounded corners. The favicon is a fixed bitmap, so we
    /// clear `contentTintColor` tinting (which only applies to template symbols).
    private func applyFavicon(_ image: NSImage, to serviceID: String) {
        guard let button = sidebarButtons[serviceID] else { return }
        let side = SidebarSize.current.icon + 4   // favicons read a touch larger than glyphs
        let radius = side * 0.24
        let rounded = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
            path.addClip()
            image.draw(in: rect)
            return true
        }
        rounded.isTemplate = false
        button.image = rounded
        button.imageScaling = .scaleProportionallyUpOrDown
    }

    // MARK: - App-icon styling (bare rounded favicon + active ring + asleep dimming)

    /// The Wasabi green for the active-service ring.
    private static let ringColor = NSColor(red: 0.655, green: 0.847, blue: 0.298, alpha: 1) // #A7D84C
    /// Opacity of a slept service's icon — dimmed to signal it's released its RAM.
    private static let asleepAlpha: CGFloat = 0.4

    // MARK: - Service menu (right-click)

    /// The three policies offered per service, with display titles.
    private var policyChoices: [(title: String, policy: SleepPolicy)] {
        [
            ("Keep running", .keepRunning),
            ("Sleep after 5 min", .sleepAfterDefault),
            ("Smart sleep", .smartSleep),
        ]
    }

    private enum ServiceMenuTag {
        static let back = 100
        static let sleepNow = 101
        static let reload = 102
    }

    private func makeServiceMenu(for serviceID: String) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self

        let backItem = NSMenuItem(title: "Back", action: #selector(backItemSelected(_:)), keyEquivalent: "")
        backItem.target = self
        backItem.representedObject = serviceID
        backItem.tag = ServiceMenuTag.back
        backItem.setSymbol("chevron.backward")
        menu.addItem(backItem)

        // Reload this service in place. Disabled while asleep (nothing loaded to
        // refresh — it cold-loads on wake) — see menuNeedsUpdate.
        let reloadItem = NSMenuItem(title: "Reload",
                                    action: #selector(reloadServiceSelected(_:)),
                                    keyEquivalent: "")
        reloadItem.target = self
        reloadItem.representedObject = serviceID
        reloadItem.tag = ServiceMenuTag.reload
        reloadItem.setSymbol("arrow.clockwise")
        menu.addItem(reloadItem)

        // Sleep this service right now (release its WebContent process) regardless
        // of policy. Disabled for the active service and one already asleep — see
        // menuNeedsUpdate.
        let sleepNowItem = NSMenuItem(title: "Sleep now",
                                      action: #selector(sleepNowSelected(_:)),
                                      keyEquivalent: "")
        sleepNowItem.target = self
        sleepNowItem.representedObject = serviceID
        sleepNowItem.tag = ServiceMenuTag.sleepNow
        sleepNowItem.setSymbol("moon.zzz")
        menu.addItem(sleepNowItem)

        menu.addItem(.separator())

        // Per-policy icon; the active policy still shows the leading checkmark.
        let policySymbol: [String: String] = [
            "Keep running": "bolt.fill",
            "Sleep after 5 min": "moon",
            "Smart sleep": "moon.stars",
        ]
        let current = pool.policy(for: serviceID)
        for choice in policyChoices {
            let item = NSMenuItem(title: choice.title,
                                  action: #selector(policyItemSelected(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = serviceID
            item.tag = policyTag(choice.policy)
            item.state = (sameKind(choice.policy, current)) ? .on : .off
            item.setSymbol(policySymbol[choice.title])
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let editItem = NSMenuItem(title: "Edit…",
                                  action: #selector(editServiceSelected(_:)),
                                  keyEquivalent: "")
        editItem.target = self
        editItem.representedObject = serviceID
        editItem.setSymbol("pencil")
        menu.addItem(editItem)

        let removeItem = NSMenuItem(title: "Remove…",
                                    action: #selector(removeServiceSelected(_:)),
                                    keyEquivalent: "")
        removeItem.target = self
        removeItem.representedObject = serviceID
        removeItem.setSymbol("trash")
        menu.addItem(removeItem)

        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let serviceID = menu.items.compactMap({ $0.representedObject as? String }).first,
              let controller = controllers[serviceID] else {
            return
        }

        menu.item(withTag: ServiceMenuTag.back)?.isEnabled = controller.canGoBack
        // "Reload" needs a live page — disabled while asleep (wakes cold anyway).
        menu.item(withTag: ServiceMenuTag.reload)?.isEnabled = controller.isAwake
        // "Sleep now" only applies to an inactive, still-awake service.
        menu.item(withTag: ServiceMenuTag.sleepNow)?.isEnabled =
            (serviceID != activeID) && controller.isAwake
    }

    @objc private func sleepNowSelected(_ sender: NSMenuItem) {
        guard let serviceID = sender.representedObject as? String else { return }
        pool.sleepNow(serviceID)
    }

    /// Reload a service in place from its right-click menu — without switching to
    /// it. No-op while asleep (menu item is disabled then anyway).
    @objc private func reloadServiceSelected(_ sender: NSMenuItem) {
        guard let serviceID = sender.representedObject as? String else { return }
        controllers[serviceID]?.reload()
    }

    /// Stable tag per policy kind (timeout ignored — only the kind is offered).
    private func policyTag(_ p: SleepPolicy) -> Int {
        switch p {
        case .keepRunning:     return 0
        case .autoSleepTimer:  return 1
        case .smartSleep:      return 2
        }
    }

    private func sameKind(_ a: SleepPolicy, _ b: SleepPolicy) -> Bool {
        policyTag(a) == policyTag(b)
    }

    @objc private func policyItemSelected(_ sender: NSMenuItem) {
        guard let serviceID = sender.representedObject as? String else { return }
        let chosen = policyChoices.first { policyTag($0.policy) == sender.tag }?.policy ?? .keepRunning
        pool.setPolicy(chosen, for: serviceID)
        // Refresh checkmarks within this menu.
        sender.menu?.items.forEach { $0.state = ($0.tag == sender.tag) ? .on : .off }
    }

    @objc private func backItemSelected(_ sender: NSMenuItem) {
        guard let serviceID = sender.representedObject as? String,
              let controller = controllers[serviceID] else {
            return
        }
        select(serviceID: serviceID)
        controller.goBackIfPossible()
    }

    // MARK: - Content

    private func setupContentContainer() {
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.wantsLayer = true
        // Opaque white backdrop behind the WebView so text antialiasing has a
        // solid background to composite against (prevents thin/fuzzy glyphs).
        contentContainer.layer?.isOpaque = true
        contentContainer.layer?.backgroundColor = NSColor.white.cgColor
    }

    private func layout() {
        sidebarBG.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(sidebarBG)
        view.addSubview(contentContainer)

        sidebarWidthConstraint = sidebarBG.widthAnchor.constraint(equalToConstant: SidebarSize.current.sidebarWidth)

        NSLayoutConstraint.activate([
            sidebarBG.topAnchor.constraint(equalTo: view.topAnchor),
            sidebarBG.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            sidebarBG.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sidebarWidthConstraint,

            // Content butts directly against the glass sidebar — no divider line.
            contentContainer.topAnchor.constraint(equalTo: view.topAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: sidebarBG.trailingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        // Thin drag handle across the top of the content, above the WebView. Only
        // shown in Layout B (wide), where the hidden titlebar leaves no native grab
        // area over the content. Starts hidden; `applyWindowLayout` toggles it.
        dragStrip.translatesAutoresizingMaskIntoConstraints = false
        dragStrip.isHidden = true
        view.addSubview(dragStrip)
        NSLayoutConstraint.activate([
            dragStrip.topAnchor.constraint(equalTo: view.topAnchor),
            dragStrip.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            dragStrip.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            dragStrip.heightAnchor.constraint(equalToConstant: 12),
        ])
    }

    // MARK: - Window layout (Layout A standard titlebar vs Layout B full-height sidebar)

    /// Switch the window between the two native layouts based on size mode:
    ///
    /// - **Layout A (compact/medium):** standard titlebar. The content view sits
    ///   below it, so the sidebar already clears the system traffic lights; its top
    ///   edge inset is just the mode's normal padding.
    /// - **Layout B (wide):** `.fullSizeContentView` + transparent titlebar — the
    ///   sidebar runs full-height under the titlebar and the window's own traffic
    ///   lights float inside the sidebar top (Finder/Notes). The first icon clears
    ///   them via a top edge inset of the *system-reported* titlebar height (read
    ///   from `contentLayoutRect`, never hardcoded), so it scales correctly.
    ///
    /// The lights are the window's own buttons throughout — we never draw or size
    /// them, so Retina/display scaling and theming are automatic.
    private func applyWindowLayout(for size: SidebarSize) {
        guard let window = view.window else { return }

        if size == .wide {
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            dragStrip.isHidden = false    // explicit grab area over the content top
        } else {
            window.styleMask.remove(.fullSizeContentView)
            window.titlebarAppearsTransparent = false
            window.titleVisibility = .visible
            dragStrip.isHidden = true     // real titlebar handles dragging
        }
        updateSidebarTopInset()
    }

    /// Set the sidebar's top edge inset from the *current* window state. In wide
    /// (Layout B) the first icon must clear the floating traffic lights by the
    /// system-reported titlebar height; in fullscreen that height collapses to 0,
    /// and in Layout A the content already sits below a real titlebar — all three
    /// fall out of the same formula, so this is re-run on every fullscreen/layout
    /// transition rather than computed once (the source of the enter/exit overlap).
    private func updateSidebarTopInset() {
        guard let window = view.window else { return }
        let edge = SidebarSize.current.edgeInset
        let titlebar = SidebarSize.current == .wide
            ? max(0, window.frame.height - window.contentLayoutRect.height)
            : 0
        window.layoutIfNeeded()
        sidebar.edgeInsets = NSEdgeInsets(top: titlebar + edge, left: 0, bottom: edge, right: 0)
    }

    // MARK: - Freemium gates

    /// The free tier caps the service list at the first two. `index(of:)` and this
    /// limit are the whole gating rule for services — one place, so add + load stay
    /// in step. Trial/Pro lift it (isUnlocked(.unlimitedServices)).
    private static let freeServiceLimit = 2

    /// Position of a service in the current ordered list (nil if unknown).
    private func index(of serviceID: String) -> Int? {
        services.firstIndex { $0.id == serviceID }
    }

    /// True when this service sits beyond the free cap AND the user hasn't unlocked
    /// unlimited services. Drives both the add gate and the load gate.
    private func serviceLocked(_ serviceID: String) -> Bool {
        guard !LicenseManager.shared.isUnlocked(.unlimitedServices) else { return false }
        return (index(of: serviceID) ?? 0) >= Self.freeServiceLimit
    }

    /// Show the paywall (LicenseWindow in `.upgrade` mode: limit message + Buy /
    /// Activate). On a successful activation the caller's follow-up runs, so the
    /// just-blocked action completes now that the tier is `.pro`.
    private func promptUpgrade(reason: String = "Wasabi Free includes 2 services. Unlock unlimited services, Smart Sleep, drag-to-reorder and custom icons with Wasabi Pro.",
                              then onActivated: @escaping () -> Void = {}) {
        LicenseWindow(mode: .upgrade(reason: reason)).present(onActivated: onActivated)
    }

    // MARK: - Add service

    @objc private func addServiceTapped() {
        guard let window = view.window else { return }

        // Gate 1: free tier caps the list at freeServiceLimit. Adding a 3rd needs
        // Pro — offer the upgrade instead of the add sheet. Edit stays usable (it's
        // a different entry point) so a free user can still fix their two services.
        if !LicenseManager.shared.isUnlocked(.unlimitedServices),
           services.count >= Self.freeServiceLimit {
            promptUpgrade()
            return
        }

        let sheet = AddServiceSheet()
        addSheet = sheet
        sheet.present(over: window) { [weak self] result in
            self?.addSheet = nil
            guard let self, let result else { return }
            let service = self.registry.add(name: result.name, url: result.url)
            // The registry's onChange → reloadServices() inserted the controller +
            // button; now select it so it loads (which resolves its favicon).
            self.select(serviceID: service.id)
        }
    }

    // MARK: - Edit service

    @objc private func editServiceSelected(_ sender: NSMenuItem) {
        guard let serviceID = sender.representedObject as? String,
              let service = registry.service(id: serviceID),
              let window = view.window else { return }

        let sheet = AddServiceSheet(prefill: .init(name: service.name, url: service.url))
        addSheet = sheet
        sheet.present(over: window) { [weak self] result in
            self?.addSheet = nil
            guard let self, let result else { return }
            // Same id — session + policy preserved. Name + URL update in one commit
            // (one persist, one reload; no transient {new name, old URL} state).
            self.registry.update(
                id: serviceID,
                name: ServiceRegistry.displayName(result.name, for: result.url),
                url: result.url)
        }
    }

    // MARK: - Remove service

    @objc private func removeServiceSelected(_ sender: NSMenuItem) {
        guard let serviceID = sender.representedObject as? String,
              let service = registry.service(id: serviceID) else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Remove \(service.name)?"
        alert.informativeText = "This deletes its session on this Mac — you'll need to sign in again if you re-add it."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")

        let respond: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.removeService(id: serviceID)
        }
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: respond)
        } else {
            respond(alert.runModal())
        }
    }

    /// Fully remove a service: tear down its WebView (releasing the WebContent
    /// process), delete its isolated data store, clear every service-keyed
    /// UserDefaults entry (policy + datastore mapping), evict its favicon, and drop
    /// it from the registry. If it was the active service, select a neighbor.
    private func removeService(id: String) {
        guard let controller = controllers[id] else { return }

        // Pick the next active service *before* mutating, if we're removing the
        // active one. Prefer the following service, else the preceding.
        let order = services.map { $0.id }
        let nextActive: String? = {
            guard id == activeID, let i = order.firstIndex(of: id) else { return nil }
            let remaining = order.enumerated().filter { $0.element != id }
            // closest by index distance: prefer i (the one that shifts into place), else i-1
            if i < remaining.count { return remaining[i].element }
            return remaining.last?.element
        }()

        // 1. Release the WebContent process and unmount the view.
        controller.sleep()
        if let mounted = mountedWebViews[id] {
            mounted.removeFromSuperview()
            mountedWebViews[id] = nil
        }

        // 2. Drop from the pool (cancels its timers, forgets policy).
        pool.removeController(id: id)
        controllers[id] = nil

        // 3. Delete the isolated data store (if one was ever minted) + forget the
        //    id→UUID mapping so a re-added service can't bind to the dead store.
        if let uuid = DataStoreID.peek(for: id) {
            WKWebsiteDataStore.remove(forIdentifier: uuid) { error in
                if let error { DebugLog.write(id, "data store remove failed: \(error)") }
            }
        }
        DataStoreID.clear(for: id)

        // 4. Clear the per-service policy key and evict the cached favicon.
        UserDefaults.standard.removeObject(forKey: "wasabi.sleeppolicy.\(id)")
        FaviconProvider.shared.evict(serviceID: id)

        // 5. Remove the sidebar button.
        if let button = sidebarButtons[id] {
            sidebar.removeArrangedSubview(button)
            button.removeFromSuperview()
            sidebarButtons[id] = nil
        }

        // 6. Drop from the registry (onChange → reloadServices refreshes the
        //    snapshot; the additions loop finds nothing new).
        registry.remove(id: id)

        // 7. Fix selection / dock icon.
        if let next = nextActive {
            select(serviceID: next)
        } else if id == activeID {
            activeID = ""   // empty state: only the "+" remains
        }
        scheduleDynamicIconRefresh()
    }

    // MARK: - Registry sync

    /// Apply the registry's current state to the live UI/pool as an incremental
    /// delta — the single entry point for every registry change (add / rename /
    /// URL edit / reorder). Removal is handled directly in `removeService` before
    /// the registry change fires, so this only ever sees additions + edits here.
    private func reloadServices() {
        let updated = registry.all()
        services = updated

        for (index, service) in updated.enumerated() {
            if let controller = controllers[service.id] {
                // Existing service: apply rename / URL edit in place (same id, so
                // session + policy survive). Refresh the button's tooltip + menu.
                if controller.service != service {
                    controller.updateService(service)
                    sidebarButtons[service.id]?.toolTip = service.name
                }
            } else {
                // New service: build its controller + pool entry + sidebar button.
                let controller = WebViewController(service: service)
                controllers[service.id] = controller
                pool.addController(controller, policy: .smartSleep)
                let button = makeServiceButton(for: service)
                sidebar.insertArrangedSubview(button, at: index)
            }
        }

        // Reorder the sidebar to match the registry order (the "+" stays last).
        for (index, service) in updated.enumerated() {
            guard let button = sidebarButtons[service.id] else { continue }
            if sidebar.arrangedSubviews.firstIndex(of: button) != index {
                sidebar.removeArrangedSubview(button)
                sidebar.insertArrangedSubview(button, at: index)
            }
        }
    }

    // MARK: - Drag-to-reorder

    /// A floating snapshot of the button being dragged. It follows the cursor over
    /// the sidebar while the real button is hidden (but kept in the stack so its
    /// slot reflows). Gives clear "I'm holding this" feedback during the drag.
    private var dragGhost: NSImageView?
    /// Cursor offset within the button at grab time, so the ghost doesn't snap its
    /// top-left to the cursor.
    private var dragGrabOffsetY: CGFloat = 0

    /// Live drag-reorder of the sidebar service buttons. The grabbed button lifts
    /// into a floating ghost that tracks the cursor; siblings reflow around the
    /// gap as the hidden original is reordered in the stack; on release the order
    /// is committed to the registry. The "+" has no recognizer, so it stays last.
    @objc private func handleReorderPan(_ gesture: NSPanGestureRecognizer) {
        guard let button = gesture.view as? NSButton else { return }

        // Gate 3: reorder is Pro. Refuse at .began (before any ghost lifts) so no
        // later state can commit an order to the registry — and prompt once, on the
        // first drag attempt. Checked every state so a policy flip mid-gesture can't
        // slip a .changed/.ended through.
        if !LicenseManager.shared.isUnlocked(.reorderServices) {
            if gesture.state == .began { promptUpgrade() }
            return
        }

        switch gesture.state {
        case .began:
            beginDragGhost(for: button, gesture: gesture)
        case .changed:
            moveDragGhost(gesture: gesture)
            reorderDuringDrag(button, gesture: gesture)
        case .ended, .cancelled:
            endDragGhost(restoring: button)
            let order = sidebar.arrangedSubviews.compactMap { v -> String? in
                (v as? NSButton)?.identifier?.rawValue
            }.filter { sidebarButtons[$0] != nil }
            registry.setOrder(order)
        default:
            break
        }
    }

    /// Snapshot the button into a floating image view over the sidebar, then hide
    /// the real one (keeping its arranged slot so the layout still reserves space
    /// until the first reorder).
    private func beginDragGhost(for button: NSButton, gesture: NSPanGestureRecognizer) {
        guard let rep = button.bitmapImageRepForCachingDisplay(in: button.bounds) else { return }
        button.cacheDisplay(in: button.bounds, to: rep)
        let image = NSImage(size: button.bounds.size)
        image.addRepresentation(rep)

        let ghost = NSImageView(frame: view.convert(button.bounds, from: button))
        ghost.image = image
        ghost.imageScaling = .scaleNone
        ghost.wantsLayer = true
        ghost.layer?.shadowOpacity = 0.35
        ghost.layer?.shadowRadius = 6
        ghost.layer?.shadowOffset = .zero
        ghost.alphaValue = 0.95
        view.addSubview(ghost)
        dragGhost = ghost

        let locInButton = gesture.location(in: button)
        dragGrabOffsetY = button.bounds.midY - locInButton.y
        button.alphaValue = 0   // hide original; ghost stands in
    }

    /// Keep the ghost centered on the cursor (vertically), clamped to the sidebar.
    private func moveDragGhost(gesture: NSPanGestureRecognizer) {
        guard let ghost = dragGhost else { return }
        let loc = gesture.location(in: view)
        var frame = ghost.frame
        frame.origin.y = loc.y - frame.height / 2 + dragGrabOffsetY
        // Clamp within the sidebar's vertical span.
        let minY = sidebarBG.frame.minY
        let maxY = sidebarBG.frame.maxY - frame.height
        frame.origin.y = min(max(frame.origin.y, minY), maxY)
        ghost.frame = frame
    }

    /// Reorder the (hidden) real button in the stack as the cursor crosses
    /// neighbors, so the remaining buttons reflow to show where it will land.
    private func reorderDuringDrag(_ button: NSButton, gesture: NSPanGestureRecognizer) {
        let ordered = sidebar.arrangedSubviews.compactMap { v -> NSButton? in
            (v as? NSButton).flatMap { sidebarButtons.values.contains($0) ? $0 : nil }
        }
        guard let from = ordered.firstIndex(of: button) else { return }
        let dragY = gesture.location(in: sidebar).y
        var target = from
        for (i, b) in ordered.enumerated() where b !== button {
            let center = b.frame.midY
            if dragY > center, i < from { target = min(target, i) }
            if dragY < center, i > from { target = max(target, i) }
        }
        if target != from {
            sidebar.removeArrangedSubview(button)
            sidebar.insertArrangedSubview(button, at: target)
        }
    }

    private func endDragGhost(restoring button: NSButton) {
        dragGhost?.removeFromSuperview()
        dragGhost = nil
        button.alphaValue = (button.identifier?.rawValue == activeID) ? 1.0 : 0.55
    }

    // MARK: - Selection

    @objc private func serviceButtonTapped(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        select(serviceID: id)
    }

    /// Reload the active service's page (⌘R / View ▸ Reload). Wasabi has no browser
    /// chrome, so this is the only in-place refresh for a stuck/stale web app —
    /// short of a sleep/wake cold reload or an app relaunch. Session preserved.
    @objc func reloadActiveService(_ sender: Any?) {
        controllers[activeID]?.reload()
    }

    private func select(serviceID: String) {
        guard let controller = controllers[serviceID] else { return }

        // Gate 2: a locked service (beyond the free cap) can't be opened — offer the
        // upgrade instead of waking/mounting it. On activation, re-run select so it
        // opens now that the tier is Pro. Return BEFORE touching activeID/pool so the
        // locked service never becomes active or wakes.
        if serviceLocked(serviceID) {
            promptUpgrade { [weak self] in self?.select(serviceID: serviceID) }
            return
        }

        activeID = serviceID

        // Read *before* setActive wakes the service (which clears the flag on the
        // rebuilt controller). A slept service reloads cold — cover the blank
        // WebView with the wake overlay until its `didFinish` fades it out.
        let wasSlept = controller.wasSlept

        // The pool wakes this service and re-schedules the one being left
        // according to its per-service SleepPolicy (timer / smart / keepRunning).
        pool.setActive(serviceID)

        // Mount the WebView once, then just toggle visibility on subsequent
        // switches. Re-mounting (removeFromSuperview + addSubview + activating
        // fresh constraints) on every switch thrashes Auto Layout and is the
        // source of switch-time hitching. A WebView that was slept and rebuilt
        // by `pool.setActive` reports a different identity, so remount if needed.
        let webView = controller.webView
        mount(webView, for: serviceID)

        if wasSlept {
            showWakeOverlay()
            // Fade out once the reloaded page paints. Assigned per-select so it
            // targets the currently-woken controller.
            controller.onDidFinish = { [weak self] in self?.hideWakeOverlay() }
        }

        // Show the active WebView, and remove all other WebViews from the view
        // hierarchy. Keeping only the active WebView in the superview prevents
        // hidden sibling WebViews (whose out-of-process WebKit drag registration
        // survives window-level visibility checks) from intercepting and refusing
        // drag-and-drop events aimed at the active WebView.
        for (id, view) in mountedWebViews {
            if id == serviceID {
                view.isHidden = false
            } else {
                // Full removal, not just `isHidden`: a view with no superview has a
                // nil window, so WebKit's out-of-process drag destination can't
                // route a file drag to a background service and refuse it — the
                // failure that made drops die after visiting another service.
                view.removeFromSuperview()
            }
        }

        // `isHidden` does NOT make WebKit throttle a hidden-but-mounted WebView —
        // its timers/rAF keep running. Drive the Page Visibility API instead so
        // each inactive service reports `document.hidden` and backs off on its
        // own (the standards-defined "you're backgrounded" signal), while staying
        // mounted for instant switch-back. The active one is marked visible.
        for (id, ctrl) in controllers {
            ctrl.setVisible(id == serviceID)
        }

        controller.loadIfNeeded()
        updateSelectionHighlight()
    }

    /// Drop mounted views whose service has slept. `sleep()` releases the
    /// controller's reference, but this map still retained the WKWebView —
    /// keeping its WebContent process (and RAM) alive until the next select,
    /// and leaving a stale registered drag destination in the window. Slept ⇒
    /// unmount and release; the next select remounts the rebuilt view.
    private func pruneSleptWebViews() {
        for (id, view) in mountedWebViews where controllers[id]?.isAwake == false {
            view.removeFromSuperview()
            mountedWebViews[id] = nil
        }
    }

    /// WebViews currently mounted in the content container, keyed by service id.
    /// Lets us reuse the same mounted view (and its constraints) across switches.
    private var mountedWebViews: [String: NSView] = [:]

    /// Mount a service's WebView into the container exactly once. If the service
    /// was slept its WebView is rebuilt with a new identity, so we replace the
    /// stale mounted instance; otherwise this is a no-op.
    private func mount(_ webView: NSView, for serviceID: String) {
        if let existing = mountedWebViews[serviceID] {
            if existing === webView {
                // Ensure it is added to the superview since inactive views are removed
                // from superview to prevent drag-and-drop interception.
                if webView.superview == nil {
                    webView.translatesAutoresizingMaskIntoConstraints = false
                    contentContainer.addSubview(webView)
                    NSLayoutConstraint.activate([
                        webView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
                        webView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
                        webView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
                        webView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
                    ])
                }
                return
            }
            existing.removeFromSuperview()          // stale (rebuilt after sleep) — replace
        }
        webView.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            webView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
        ])
        mountedWebViews[serviceID] = webView
    }

    // MARK: - Wake overlay

    /// A "Waking…" curtain (moon + spinner) shown over the content while a slept
    /// service reloads its blank, cold WebView, then faded out on `didFinish`.
    /// Masks the white loading flash so waking reads as a soft fade-in, not a
    /// pop-in, and the spinner shows the reload is in progress (a cold load can
    /// take several seconds).
    private var wakeOverlay: NSView?

    /// When the current overlay became visible, so a very fast (warm-cache) reload
    /// still shows the spinner for a readable beat instead of flashing for a frame.
    private var wakeOverlayShownAt: Date?
    /// Minimum time the overlay stays fully visible before it may fade.
    private static let wakeOverlayMinHold: TimeInterval = 0.5

    /// The spinner inside the overlay — kept so we can start/stop it with the
    /// overlay's show/hide (an animating NSProgressIndicator burns cycles).
    private var wakeSpinner: NSProgressIndicator?

    /// Build the overlay lazily: a moon + "Waking…" line above an indeterminate
    /// spinner, centered on the content background, filling the content container
    /// above the WebView. The spinner tells the user the reload is in progress —
    /// a cold WhatsApp/Telegram load can take several seconds, and without it the
    /// static moon reads as "stuck". Indeterminate because WebKit gives no real
    /// load percentage.
    private func makeWakeOverlay() -> NSView {
        let overlay = NSView()
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.wantsLayer = true
        overlay.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let moon = NSImageView()
        moon.image = NSImage(systemSymbolName: "moon.fill", accessibilityDescription: "Waking")
        moon.symbolConfiguration = .init(pointSize: 22, weight: .regular)
        moon.contentTintColor = .tertiaryLabelColor

        let label = NSTextField(labelWithString: "Waking…")
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .tertiaryLabelColor

        let row = NSStackView(views: [moon, label])
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY

        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        wakeSpinner = spinner

        let column = NSStackView(views: [row, spinner])
        column.orientation = .vertical
        column.spacing = 12
        column.alignment = .centerX
        column.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(column)
        NSLayoutConstraint.activate([
            column.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            column.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
        ])
        return overlay
    }

    private func showWakeOverlay() {
        // Reuse a single overlay instance; a rapid re-select just resets its alpha.
        let overlay = wakeOverlay ?? makeWakeOverlay()
        wakeOverlay = overlay
        if overlay.superview !== contentContainer {
            overlay.removeFromSuperview()
            contentContainer.addSubview(overlay)   // above the WebView (added last)
            NSLayoutConstraint.activate([
                overlay.topAnchor.constraint(equalTo: contentContainer.topAnchor),
                overlay.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
                overlay.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
                overlay.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            ])
        } else {
            contentContainer.addSubview(overlay)   // re-raise above the freshly-mounted WebView
        }
        overlay.alphaValue = 1
        overlay.isHidden = false
        wakeOverlayShownAt = Date()
        wakeSpinner?.startAnimation(nil)
    }

    private func hideWakeOverlay() {
        guard let overlay = wakeOverlay, !overlay.isHidden else { return }
        // Hold the overlay at least `wakeOverlayMinHold` so a warm-cache reload
        // (didFinish in <100ms) doesn't flash the spinner for a single frame;
        // a slow reload is already past the floor and fades immediately.
        let shown = wakeOverlayShownAt.map { Date().timeIntervalSince($0) } ?? .greatestFiniteMagnitude
        let remaining = Self.wakeOverlayMinHold - shown
        if remaining > 0 {
            let delay = remaining
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.fadeOutWakeOverlay()
            }
        } else {
            fadeOutWakeOverlay()
        }
    }

    private func fadeOutWakeOverlay() {
        guard let overlay = wakeOverlay, !overlay.isHidden else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.35
            overlay.animator().alphaValue = 0
        } completionHandler: { [weak self, weak overlay] in
            overlay?.isHidden = true
            self?.wakeSpinner?.stopAnimation(nil)   // don't spin an unseen indicator
        }
    }

    /// Active icon gets a thin green ring with a gap around it (drawn at the button
    /// edge, larger than the favicon). Asleep services (WebContent released) are
    /// dimmed so you can see at a glance which ones have reclaimed their RAM; awake
    /// and active services show at full opacity.
    private func updateSelectionHighlight() {
        let tile = SidebarSize.current.tile
        for (id, button) in sidebarButtons {
            let active = (id == activeID)
            guard let layer = button.layer else { continue }
            // Ring at the button edge → a natural gap to the smaller favicon inside.
            layer.cornerRadius = tile / 2          // pill — matches round favicons
            layer.borderWidth = active ? 2 : 0
            layer.borderColor = active ? Self.ringColor.cgColor : nil
            // Template SF-Symbol placeholders still tint; favicons ignore it.
            button.contentTintColor = active ? .controlAccentColor : .secondaryLabelColor
            // Dim asleep services; the active one is always live.
            let awake = active || (controllers[id]?.isAwake ?? false)
            button.alphaValue = awake ? 1.0 : Self.asleepAlpha
        }
    }
}

/// A stack view whose empty areas drag the window. In wide/Layout B the lights
/// live in the transparent titlebar and the title is hidden, so the sidebar's top
/// inset (above the first icon) is the natural place to grab the window — like
/// Finder/Notes. Buttons are subviews and receive their own clicks first; only
/// clicks that fall on the stack's own background propagate as a window drag.
final class DraggableStackView: NSStackView {
    override var mouseDownCanMoveWindow: Bool { true }
}

/// A thin transparent strip across the window top that reliably drags the window.
/// In wide/Layout B the title is hidden and the WebView fills the content, eating
/// background-drag events — so we put an explicit drag handle over the top edge and
/// call `performDrag` directly, which never misses. Sits above the content, right
/// of the traffic lights; double-click zooms, matching native titlebar behavior.
final class WindowDragStrip: NSView {
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { window?.performZoom(nil) }
        else { window?.performDrag(with: event) }
    }
}
