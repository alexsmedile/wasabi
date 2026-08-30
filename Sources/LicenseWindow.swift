import AppKit

/// Upgrade and activation UI on one window so every path shares the same product
/// copy and license-key handling.
///
/// - **`.activate`** — straight to the "paste your key" field.
/// - **`.upgrade(feature:)`** — a paywall shown when a free user hits a locked
///   feature or opens License from the menu. It shows the current Pro offer and
///   shipped features before Buy, Trial, and Activate actions.
///
/// Modeled on `AddServiceSheet` (`retain = self` lifetime); a standalone window,
/// not a sheet, because at launch there's no parent yet.
@MainActor
final class LicenseWindow: NSObject, NSTextFieldDelegate, NSWindowDelegate {
    /// What brought the window up — sets the copy and whether the paywall shows.
    enum Mode {
        case activate                 // already purchased: paste the key
        case upgrade(reason: String)  // a gate: show the offer first, key field on demand
        case activated                // already Pro: show status + Deactivate, no key field
    }

    /// Pick the right mode for the App menu ▸ License… entry point: an already-Pro
    /// user sees their status, everyone else sees the Pro offer. One call so the
    /// menu doesn't branch on tier itself.
    static func forMenu(manager: LicenseManager? = nil) -> LicenseWindow {
        let m = manager ?? .shared
        return LicenseWindow(
            mode: m.tier == .pro ? .activated : .upgrade(reason: ""),
            manager: m
        )
    }

    /// Checkout URL for Wasabi Pro, injected at build time via the `WASABICheckoutURL`
    /// Info.plist key (populated from `$WASABI_CHECKOUT_URL` in the author's release
    /// build). Absent in source builds ⇒ `nil` ⇒ the Buy button is disabled (no dead
    /// link). Not embedded in source so the public repo carries no store URL.
    private static func bundledURL(for key: String) -> URL? {
        guard let s = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !s.isEmpty else { return nil }
        return URL(string: s)
    }

    static let checkoutURL = bundledURL(for: "WASABICheckoutURL")
    static let proInfoURL = bundledURL(for: "WASABIProInfoURL")
    private static var presentedCount = 0
    static var isPresenting: Bool { presentedCount > 0 }

    private let window: NSWindow
    private let manager: LicenseManager
    private var onComplete: (() -> Void)?
    private var retain: LicenseWindow?
    private let mode: Mode
    private var isPresented = false

    // Paywall header (shown only in .upgrade mode).
    private let offerStack = NSStackView()
    private let buyButton = NSButton()

    // Key entry (hidden in .upgrade mode until "Activate" is tapped).
    private let keyStack = NSStackView()
    private let keyField = NSTextField()
    private let statusLabel = NSTextField(labelWithString: "")
    private let activateButton = NSButton()

    // Activated panel (shown in .activated mode: status + masked key + Deactivate).
    private let activatedStack = NSStackView()

    // manager is nil-defaulted (not `= .shared`) so the default isn't evaluated in a
    // nonisolated context — a Swift 6 error. Resolve `.shared` in the @MainActor body.
    init(mode: Mode = .activate, manager: LicenseManager? = nil) {
        self.mode = mode
        self.manager = manager ?? .shared
        let styleMask: NSWindow.StyleMask = [.titled, .closable]
        let windowSize: NSSize = switch mode {
        case .upgrade: NSSize(width: 460, height: 260)
        case .activate: NSSize(width: 440, height: 220)
        case .activated: NSSize(width: 440, height: 200)
        }
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        super.init()
        window.title = if case .upgrade = mode { "Upgrade" } else { "Wasabi Pro" }
        window.delegate = self       // drop `retain` on ANY close (✕ / close() / quit)
        // CRITICAL: a titled NSWindow defaults to isReleasedWhenClosed = true, so
        // AppKit releases the window itself during its close animation
        // (_NSWindowTransformAnimation). But WE also own it via `retain`/`window`.
        // Both releasing = double-free → crash in objc_release under the close
        // transaction. Turn AppKit's release OFF so `retain` is the sole owner.
        window.isReleasedWhenClosed = false
        buildContent()
    }

    /// The ONLY place the self-retain is released. Fires for every dismissal path —
    /// the titlebar ✕, `window.close()` after activation, and app termination — so
    /// the window can never leak or linger on screen after it's closed. Safe to clear
    /// synchronously now that `isReleasedWhenClosed = false` makes `retain` the sole
    /// owner: no double-release with AppKit's own close teardown.
    func windowWillClose(_ notification: Notification) {
        if isPresented {
            Self.presentedCount = max(0, Self.presentedCount - 1)
            isPresented = false
        }
        onComplete = nil
        retain = nil
    }

    /// Show the window centered. `onComplete` fires after a trial start or
    /// successful key activation.
    func present(onComplete: @escaping () -> Void) {
        guard !isPresented else { return }
        isPresented = true
        Self.presentedCount += 1
        if case .upgrade = mode {
            manager.markProOfferSeen()
        }
        self.onComplete = onComplete
        retain = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        switch mode {
        case .activate: window.makeFirstResponder(keyField)
        case .upgrade, .activated: break
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildContent() {
        let content = NSView(frame: window.contentLayoutRect)
        window.contentView = content

        buildOfferHeader()   // hidden unless .upgrade
        buildKeyEntry()      // hidden unless .activate
        buildActivatedPanel()// hidden unless .activated

        let stack = NSStackView(views: [offerStack, keyStack, activatedStack])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            offerStack.widthAnchor.constraint(equalTo: stack.widthAnchor),
            keyStack.widthAnchor.constraint(equalTo: stack.widthAnchor),
            activatedStack.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

        // Mode drives initial visibility: paywall-first / key-field-first / status.
        offerStack.isHidden = true
        keyStack.isHidden = true
        activatedStack.isHidden = true
        switch mode {
        case .activate:  keyStack.isHidden = false
        case .upgrade:   offerStack.isHidden = false
        case .activated: activatedStack.isHidden = false
        }
    }

    // MARK: - Offer header (.upgrade)

    private func buildOfferHeader() {
        let title = NSTextField(labelWithString: ProductCopy.proHeadline)
        title.font = .boldSystemFont(ofSize: 18)

        let offer = NSTextField(labelWithString: ProductCopy.launchOffer)
        offer.font = .boldSystemFont(ofSize: 12)

        let reason: String
        if case .upgrade(let r) = mode { reason = r } else { reason = "" }
        let body = NSTextField(wrappingLabelWithString: reason)
        body.font = .systemFont(ofSize: 11)
        body.textColor = .secondaryLabelColor
        body.isHidden = reason.isEmpty

        let features = makeFeatureList()

        buyButton.title = "Upgrade"
        buyButton.bezelStyle = .rounded
        buyButton.target = self
        buyButton.action = #selector(buyTapped)
        buyButton.isEnabled = (Self.checkoutURL != nil)   // no dead link
        buyButton.toolTip = Self.checkoutURL == nil ? "Checkout link not configured yet" : nil

        let continueFree = NSButton(title: "Continue with Free", target: self, action: #selector(continueFreeTapped))
        continueFree.bezelStyle = .rounded
        continueFree.keyEquivalent = "\r"       // calm default action, on the right

        let buttons = NSStackView(views: [buyButton, NSView(), continueFree])
        buttons.orientation = .horizontal
        buttons.spacing = 10

        var linkViews: [NSView] = []
        if manager.canStartTrial {
            let trial = NSButton(title: "Try Pro Free", target: self, action: #selector(startTrialTapped))
            trial.bezelStyle = .inline
            linkViews.append(trial)
        }
        if Self.proInfoURL != nil {
            let discover = NSButton(title: "Discover Pro", target: self, action: #selector(discoverTapped))
            discover.bezelStyle = .inline
            linkViews.append(discover)
        }
        let haveKey = NSButton(title: "Activate License", target: self, action: #selector(showKeyEntry))
        haveKey.bezelStyle = .inline
        linkViews.append(haveKey)
        let links = NSStackView(views: linkViews)
        links.orientation = .horizontal
        links.spacing = 12

        offerStack.orientation = .vertical
        offerStack.alignment = .leading
        offerStack.spacing = 9
        offerStack.setViews([title, features, offer, body, buttons, links], in: .leading)

        buttons.widthAnchor.constraint(equalTo: offerStack.widthAnchor).isActive = true
        body.widthAnchor.constraint(equalTo: offerStack.widthAnchor).isActive = true
        features.widthAnchor.constraint(equalTo: offerStack.widthAnchor).isActive = true
    }

    private func makeFeatureList() -> NSTextField {
        let text = ProductCopy.proFeatures.map { "✓  \($0)" }.joined(separator: "\n")
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.maximumNumberOfLines = ProductCopy.proFeatures.count
        return label
    }

    // MARK: - Key entry (.activate, or .upgrade after "Activate")

    private func buildKeyEntry() {
        let title = NSTextField(labelWithString: "Enter your license key")
        title.font = .boldSystemFont(ofSize: 14)

        let subtitle = NSTextField(wrappingLabelWithString: "Paste the key from your purchase email to unlock Wasabi Pro.")
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor

        keyField.placeholderString = "XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX"
        keyField.delegate = self
        keyField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.maximumNumberOfLines = 2

        activateButton.title = "Activate"
        activateButton.bezelStyle = .rounded
        activateButton.target = self
        activateButton.action = #selector(activateTapped)
        activateButton.keyEquivalent = "\r"
        activateButton.isEnabled = false

        var buttonViews: [NSView] = []
        if case .activate = mode {
            // A direct activation window has no previous panel.
        } else {
            let back = NSButton(title: "Back", target: self, action: #selector(showPreviousPanel))
            back.bezelStyle = .rounded
            buttonViews.append(back)
        }
        buttonViews.append(NSView())
        buttonViews.append(activateButton)
        let buttons = NSStackView(views: buttonViews)
        buttons.orientation = .horizontal

        keyStack.orientation = .vertical
        keyStack.alignment = .leading
        keyStack.spacing = 8
        keyStack.setViews([title, subtitle, keyField, statusLabel, buttons], in: .leading)

        keyField.widthAnchor.constraint(equalTo: keyStack.widthAnchor).isActive = true
        subtitle.widthAnchor.constraint(equalTo: keyStack.widthAnchor).isActive = true
        buttons.widthAnchor.constraint(equalTo: keyStack.widthAnchor).isActive = true
    }

    // MARK: - Activated panel (.activated)

    private func buildActivatedPanel() {
        let title = NSTextField(labelWithString: "Wasabi Pro — Activated ✓")
        title.font = .boldSystemFont(ofSize: 14)
        title.textColor = .systemGreen

        let body = NSTextField(wrappingLabelWithString: "All features are unlocked on this Mac. Your license is active.")
        body.font = .systemFont(ofSize: 12)
        body.textColor = .secondaryLabelColor

        let keyLine = NSTextField(labelWithString: "License: \(manager.maskedKey ?? "—")")
        keyLine.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        keyLine.textColor = .tertiaryLabelColor

        let deactivate = NSButton(title: "Deactivate…", target: self, action: #selector(deactivateTapped))
        deactivate.bezelStyle = .rounded

        let done = NSButton(title: "Done", target: self, action: #selector(doneTapped))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"

        let buttons = NSStackView(views: [deactivate, NSView(), done]) // deactivate left, done right
        buttons.orientation = .horizontal
        buttons.spacing = 10

        activatedStack.orientation = .vertical
        activatedStack.alignment = .leading
        activatedStack.spacing = 8
        activatedStack.setViews([title, body, keyLine, buttons], in: .leading)

        buttons.widthAnchor.constraint(equalTo: activatedStack.widthAnchor).isActive = true
        body.widthAnchor.constraint(equalTo: activatedStack.widthAnchor).isActive = true
    }

    @objc private func doneTapped() { window.close() }

    /// Deactivate this Mac: confirm, release the LS seat + clear local state, then
    /// close. The tier drops back to trial/free and the gates re-arm on next check.
    @objc private func deactivateTapped() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Deactivate Wasabi Pro on this Mac?"
        alert.informativeText = "This frees the license seat so you can use it on another Mac. Your services and sessions stay — but Pro features lock until you activate again."
        alert.addButton(withTitle: "Deactivate")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            self.manager.deactivate()
            self.window.close()
        }
    }

    // MARK: - Actions

    @objc private func buyTapped() {
        guard let url = Self.checkoutURL else { return }
        NSWorkspace.shared.open(url)
        // Leave the window open — after buying they come back and hit Activate.
    }

    @objc private func discoverTapped() {
        guard let url = Self.proInfoURL else { return }
        NSWorkspace.shared.open(url)
    }

    /// Dismiss an upgrade offer without changing entitlement or replaying the
    /// action that required Pro. Community remains fully usable.
    @objc private func continueFreeTapped() {
        window.close()
    }

    @objc private func startTrialTapped() {
        manager.startTrial()
        let completion = onComplete
        onComplete = nil
        completion?()
        window.close()
    }

    /// .upgrade → swap the paywall for the key field in place.
    @objc private func showKeyEntry() {
        offerStack.isHidden = true
        keyStack.isHidden = false
        window.makeFirstResponder(keyField)
    }

    @objc private func showPreviousPanel() {
        keyStack.isHidden = true
        switch mode {
        case .upgrade:
            offerStack.isHidden = false
            window.makeFirstResponder(nil)
        case .activate, .activated:
            break
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        let trimmed = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        activateButton.isEnabled = !trimmed.isEmpty
        statusLabel.stringValue = ""
    }

    @objc private func activateTapped() {
        let key = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        activateButton.isEnabled = false
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.stringValue = "Checking…"

        Task {
            let status = await manager.activate(key: key)
            switch status {
            case .valid:
                // Acknowledge the moment: green confirmation, run the caller's
                // follow-up (re-runs the just-blocked action as Pro), then close
                // after a short beat so success is seen, not a silent vanish.
                statusLabel.textColor = .systemGreen
                statusLabel.stringValue = "Activated — you're Pro! ✓"
                activateButton.isEnabled = false
                let completion = onComplete
                onComplete = nil
                completion?()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { [weak self] in
                    self?.window.close()   // → windowWillClose clears onComplete + retain
                }
            case .invalid(let reason):
                statusLabel.textColor = .systemRed
                statusLabel.stringValue = reason
                activateButton.isEnabled = true
            case .unreachable:
                statusLabel.textColor = .systemRed
                statusLabel.stringValue = "Couldn't reach the license server. Check your connection and try again."
                activateButton.isEnabled = true
            }
        }
    }
}
