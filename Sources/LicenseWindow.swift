import AppKit

/// Upgrade and activation UI on one window so every path shares the same product
/// copy and license-key handling.
///
/// - **`.activate`** — straight to the "paste your key" field.
/// - **`.upgrade(context:)`** — a paywall shown when a free user hits a locked
///   feature or opens License from the menu. It shows the current Pro offer and
///   shipped features before Buy, Trial, and Activate actions.
/// - **`.trialExpired`** — the one-time, non-blocking expiry notice. It never
///   deletes or mutates services; the existing free-tier gates decide availability.
///
/// Modeled on `AddServiceSheet` (`retain = self` lifetime); a standalone window,
/// not a sheet, because at launch there's no parent yet.
@MainActor
final class LicenseWindow: NSObject, NSTextFieldDelegate, NSWindowDelegate {
    /// What brought the window up — sets the copy and whether the paywall shows.
    enum Mode {
        case activate                 // already purchased: paste the key
        case upgrade(ProductCopy.UpgradeContext)
        case trialExpired(hasLockedServices: Bool)
        case activated                // already Pro: show status + Deactivate, no key field
    }

    /// Pick the right mode for the App menu ▸ License… entry point: an already-Pro
    /// user sees their status, everyone else sees the Pro offer. One call so the
    /// menu doesn't branch on tier itself.
    static func forMenu(manager: LicenseManager? = nil) -> LicenseWindow {
        let m = manager ?? .shared
        return LicenseWindow(
            mode: m.tier == .pro ? .activated : .upgrade(.general),
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
        case .upgrade: NSSize(width: 460, height: 280)
        case .trialExpired: NSSize(width: 460, height: 265)
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
        window.title = switch mode {
        case .upgrade: "Upgrade"
        case .trialExpired: "Pro Trial Ended"
        case .activate, .activated: "Wasabi Pro"
        }
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
        switch mode {
        case .upgrade:
            manager.markProOfferSeen()
            manager.markTrialExpiryNoticeSeenIfExpired()
        case .trialExpired:
            manager.markTrialExpiryNoticeSeen()
        case .activate, .activated:
            break
        }
        self.onComplete = onComplete
        retain = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        switch mode {
        case .activate: window.makeFirstResponder(keyField)
        case .upgrade, .trialExpired, .activated: break
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildContent() {
        let content = NSView(frame: window.contentLayoutRect)
        window.contentView = content

        // Build only panels this mode can reach. In particular, do not construct
        // the hidden Activated panel for an offer: it asks `maskedKey` for the
        // Keychain value and could trigger a completely unnecessary password
        // prompt while the user is only looking at Upgrade.
        switch mode {
        case .activate:
            buildKeyEntry()
        case .upgrade, .trialExpired:
            buildOfferHeader()
            buildKeyEntry()  // reachable through “Already have a key?”
        case .activated:
            buildActivatedPanel()
        }

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
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -16),
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
        case .upgrade, .trialExpired: offerStack.isHidden = false
        case .activated: activatedStack.isHidden = false
        }
    }

    // MARK: - Offer header (.upgrade)

    private func buildOfferHeader() {
        let titleText: String = switch mode {
        case .upgrade(let context): context.headline
        case .trialExpired: ProductCopy.trialEndedHeadline
        case .activate, .activated: ""
        }
        let title = NSTextField(labelWithString: titleText)
        title.font = .boldSystemFont(ofSize: isTrialExpiry ? 22 : 18)

        let offer = NSTextField(labelWithString: ProductCopy.launchOffer)
        offer.font = .boldSystemFont(ofSize: 13)

        let reassurance = NSTextField(labelWithString: ProductCopy.purchaseReassurance)
        reassurance.font = .systemFont(ofSize: 11)
        reassurance.textColor = .secondaryLabelColor

        let reason: String = switch mode {
        case .upgrade(let context): context.subtitle
        case .trialExpired(let hasLockedServices):
            hasLockedServices
                ? "\(ProductCopy.trialEndedSummary)\n\n\(ProductCopy.servicesSafeNote)"
                : ProductCopy.trialEndedSummary
        case .activate, .activated: ""
        }
        let body = NSTextField(wrappingLabelWithString: reason)
        body.font = isTrialExpiry
            ? .systemFont(ofSize: 11)
            : .systemFont(ofSize: 14, weight: .medium)
        body.textColor = isTrialExpiry ? .secondaryLabelColor : .labelColor
        body.isHidden = reason.isEmpty

        let features = makeFeatureList(compact: isTrialExpiry)

        buyButton.title = "Upgrade for \(ProductCopy.launchPrice) →"
        buyButton.bezelStyle = .rounded
        buyButton.target = self
        buyButton.action = #selector(buyTapped)
        buyButton.isEnabled = (Self.checkoutURL != nil)   // no dead link
        buyButton.toolTip = Self.checkoutURL == nil ? "Checkout link not configured yet" : nil

        let continueTitle = isDayOneOffer ? "Keep Using Trial" : "Continue with Free"
        let continueFree = NSButton(title: continueTitle, target: self, action: #selector(continueFreeTapped))

        // An unsolicited day-one offer stays calm: dismiss is the default. At an
        // explicit feature gate or the one-time expiry notice, Upgrade becomes the
        // primary action while Wasabi Free remains one click away.
        let purchaseIsPrimary = !isDayOneOffer && Self.checkoutURL != nil
        if purchaseIsPrimary {
            continueFree.bezelStyle = .rounded
            buyButton.keyEquivalent = "\r"
        } else {
            continueFree.bezelStyle = .rounded
            continueFree.keyEquivalent = "\r"
        }
        let buttonViews: [NSView] = purchaseIsPrimary
            ? [continueFree, NSView(), buyButton]
            : [buyButton, NSView(), continueFree]
        let buttons = NSStackView(views: buttonViews)
        buttons.orientation = .horizontal
        buttons.spacing = 10

        var linkViews: [NSView] = []
        if manager.canStartTrial {
            let trial = NSButton(title: "Try Pro Free", target: self, action: #selector(startTrialTapped))
            styleAsTextLink(trial)
            linkViews.append(trial)
        }
        if Self.proInfoURL != nil {
            let discover = NSButton(title: "Discover Pro", target: self, action: #selector(discoverTapped))
            styleAsTextLink(discover)
            linkViews.append(discover)
            let separator = NSTextField(labelWithString: "·")
            separator.font = .systemFont(ofSize: 11)
            separator.textColor = .tertiaryLabelColor
            linkViews.append(separator)
        }
        let keyPrompt = NSTextField(labelWithString: "Already have a key?")
        keyPrompt.font = .systemFont(ofSize: 11)
        keyPrompt.textColor = .secondaryLabelColor
        let haveKey = NSButton(title: "Activate License", target: self, action: #selector(showKeyEntry))
        styleAsTextLink(haveKey)
        let keyLink = NSStackView(views: [keyPrompt, haveKey])
        keyLink.orientation = .horizontal
        keyLink.alignment = .centerY
        keyLink.spacing = 4
        linkViews.append(keyLink)
        let links = NSStackView(views: linkViews)
        links.orientation = .horizontal
        links.spacing = 12

        offerStack.orientation = .vertical
        offerStack.alignment = .leading
        offerStack.spacing = 10
        let views: [NSView] = isTrialExpiry
            ? [title, offer, reassurance, features, body, buttons, links]
            : [title, body, features, offer, reassurance, buttons, links]
        offerStack.setViews(views, in: .leading)

        buttons.widthAnchor.constraint(equalTo: offerStack.widthAnchor).isActive = true
        body.widthAnchor.constraint(equalTo: offerStack.widthAnchor).isActive = true
        features.widthAnchor.constraint(equalTo: offerStack.widthAnchor).isActive = true
    }

    private var isTrialExpiry: Bool {
        if case .trialExpired = mode { return true }
        return false
    }

    private var isDayOneOffer: Bool {
        if case .upgrade(let context) = mode { return context.isUnsolicited }
        return false
    }

    private func styleAsTextLink(_ button: NSButton) {
        button.isBordered = false
        button.font = .systemFont(ofSize: 11)
        button.contentTintColor = .linkColor
        button.attributedTitle = NSAttributedString(
            string: button.title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ]
        )
    }

    private func makeFeatureList(compact: Bool) -> NSTextField {
        let text = compact
            ? ProductCopy.compactProFeatures
            : ProductCopy.proFeatures.map { "✓  \($0)" }.joined(separator: "\n")
        let label = NSTextField(wrappingLabelWithString: text)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = compact ? 0 : 4
        label.attributedStringValue = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph,
            ]
        )
        label.maximumNumberOfLines = compact ? 1 : ProductCopy.proFeatures.count
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
    /// action that required Pro. Wasabi Free remains fully usable.
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
        case .upgrade, .trialExpired:
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
