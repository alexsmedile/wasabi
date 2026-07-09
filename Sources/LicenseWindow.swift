import AppKit

/// Activation UI, in two modes on one window (so there's a single activation path):
///
/// - **`.activate`** (default) — straight to the "paste your key" field. Used by
///   the App menu ▸ License… entry and the original launch gate.
/// - **`.upgrade(feature:)`** — a paywall shown when a free user hits a locked
///   feature: a plain-language "you've reached the limit" message + a **Buy
///   License** button (opens the checkout) and an **Activate** button that reveals
///   the key field in place for someone who already bought. No key field until they
///   ask for it.
///
/// Modeled on `AddServiceSheet` (`retain = self` lifetime); a standalone window,
/// not a sheet, because at launch there's no parent yet.
@MainActor
final class LicenseWindow: NSObject, NSTextFieldDelegate, NSWindowDelegate {
    /// What brought the window up — sets the copy and whether the paywall shows.
    enum Mode {
        case activate                 // menu / launch: go straight to the key field
        case upgrade(reason: String)  // a gate: show the offer first, key field on demand
        case activated                // already Pro: show status + Deactivate, no key field
    }

    /// Pick the right mode for the App menu ▸ License… entry point: an already-Pro
    /// user sees their status, everyone else gets the key field. One call so the
    /// menu doesn't branch on tier itself.
    static func forMenu(manager: LicenseManager? = nil) -> LicenseWindow {
        let m = manager ?? .shared
        return LicenseWindow(mode: m.tier == .pro ? .activated : .activate, manager: m)
    }

    /// Checkout URL for Wasabi Pro, injected at build time via the `WASABICheckoutURL`
    /// Info.plist key (populated from `$WASABI_CHECKOUT_URL` in the author's release
    /// build). Absent in source builds ⇒ `nil` ⇒ the Buy button is disabled (no dead
    /// link). Not embedded in source so the public repo carries no store URL.
    static let checkoutURL: URL? = {
        guard let s = Bundle.main.object(forInfoDictionaryKey: "WASABICheckoutURL") as? String,
              !s.isEmpty else { return nil }
        return URL(string: s)
    }()

    private let window: NSWindow
    private let manager: LicenseManager
    private var onActivated: (() -> Void)?
    private var retain: LicenseWindow?
    private let mode: Mode

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
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 220),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.title = "Wasabi Pro"
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
        onActivated = nil
        retain = nil
    }

    /// Show the window centered. `onActivated` fires once, when a key is accepted.
    func present(onActivated: @escaping () -> Void) {
        self.onActivated = onActivated
        retain = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        // In .activate mode focus the field immediately; in .upgrade the field is
        // hidden, so let the buttons take focus.
        if case .activate = mode { window.makeFirstResponder(keyField) }
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
        let title = NSTextField(labelWithString: "You've reached your service limit")
        title.font = .boldSystemFont(ofSize: 14)

        let reason: String
        if case .upgrade(let r) = mode { reason = r } else { reason = "" }
        let body = NSTextField(wrappingLabelWithString: reason)
        body.font = .systemFont(ofSize: 12)
        body.textColor = .secondaryLabelColor

        buyButton.title = "Buy License"
        buyButton.bezelStyle = .rounded
        buyButton.keyEquivalent = "\r"          // primary action
        buyButton.target = self
        buyButton.action = #selector(buyTapped)
        buyButton.isEnabled = (Self.checkoutURL != nil)   // no dead link
        buyButton.toolTip = Self.checkoutURL == nil ? "Checkout link not configured yet" : nil

        let haveKey = NSButton(title: "Activate", target: self, action: #selector(showKeyEntry))
        haveKey.bezelStyle = .rounded

        let buttons = NSStackView(views: [NSView(), buyButton, haveKey]) // spacer pushes right
        buttons.orientation = .horizontal
        buttons.spacing = 10

        offerStack.orientation = .vertical
        offerStack.alignment = .leading
        offerStack.spacing = 8
        offerStack.setViews([title, body, buttons], in: .leading)

        buttons.widthAnchor.constraint(equalTo: offerStack.widthAnchor).isActive = true
        body.widthAnchor.constraint(equalTo: offerStack.widthAnchor).isActive = true
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

        let buttons = NSStackView(views: [NSView(), activateButton])
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

    /// .upgrade → swap the paywall for the key field in place.
    @objc private func showKeyEntry() {
        offerStack.isHidden = true
        keyStack.isHidden = false
        window.makeFirstResponder(keyField)
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
                onActivated?()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { [weak self] in
                    self?.window.close()   // → windowWillClose clears onActivated + retain
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
