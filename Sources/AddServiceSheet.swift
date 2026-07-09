import AppKit

/// A small AppKit sheet for adding (or editing) a service: a required URL field
/// with live validation and an optional Name field. The URL is normalized to
/// `https://` and rejected if it isn't a parseable http(s) address.
///
/// Presented from the sidebar "+". The same sheet will back the right-click
/// "Edit…" in M4 (prefilled, "Save" instead of "Add") — kept generic for that.
@MainActor
final class AddServiceSheet: NSObject, NSTextFieldDelegate {
    /// Result handed back on Add. Name may be empty — the registry falls back to
    /// the host. URL is already normalized to a valid http(s) `URL`.
    struct Result {
        let name: String
        let url: URL
    }

    /// Prefill for edit mode: existing name/URL to populate, and the labels to
    /// use. `nil` (the default) is add mode.
    struct Prefill {
        let name: String
        let url: URL
    }

    private let window: NSWindow
    private let urlField = NSTextField()
    private let nameField = NSTextField()
    private let errorLabel = NSTextField(labelWithString: "")
    private let addButton = NSButton()
    private let titleLabel = NSTextField(labelWithString: "Add a service")
    private var completion: ((Result?) -> Void)?
    private let prefill: Prefill?

    /// Strong self-reference held for the sheet's lifetime so the presenter
    /// doesn't have to retain it; cleared when the sheet ends.
    private var retain: AddServiceSheet?

    /// `prefill: nil` → add mode. A non-nil prefill → edit mode (populated fields,
    /// "Edit a service" / "Save").
    init(prefill: Prefill? = nil) {
        self.prefill = prefill
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 168),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        super.init()
        buildContent()
    }

    // MARK: - Presentation

    /// Present as a sheet on `parent`. `onComplete` is called with the entered
    /// service, or `nil` if cancelled.
    func present(over parent: NSWindow, onComplete: @escaping (Result?) -> Void) {
        completion = onComplete
        retain = self
        parent.beginSheet(window)
        window.makeFirstResponder(nameField)
        validate()
    }

    private func finish(_ result: Result?) {
        let parent = window.sheetParent
        parent?.endSheet(window)
        completion?(result)
        completion = nil
        retain = nil
    }

    // MARK: - Content

    private func buildContent() {
        let content = NSView(frame: window.contentLayoutRect)
        window.contentView = content

        let isEdit = (prefill != nil)
        titleLabel.stringValue = isEdit ? "Edit service" : "Add a service"
        titleLabel.font = .boldSystemFont(ofSize: 13)

        urlField.placeholderString = "Web address (e.g. app.slack.com)"
        urlField.delegate = self
        nameField.placeholderString = "Name (optional)"
        nameField.delegate = self
        if let prefill {
            urlField.stringValue = prefill.url.absoluteString
            nameField.stringValue = prefill.name
        }

        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.textColor = .systemRed
        errorLabel.maximumNumberOfLines = 2

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"            // Esc

        addButton.title = isEdit ? "Save" : "Add"
        addButton.bezelStyle = .rounded
        addButton.target = self
        addButton.action = #selector(addTapped)
        addButton.keyEquivalent = "\r"             // Return = default button

        let buttons = NSStackView(views: [cancel, addButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        // Name first, then URL — matches the conventional "add" dialog order, so
        // users don't type the name into the URL field (which then fails validation).
        let stack = NSStackView(views: [titleLabel, nameField, urlField, errorLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            urlField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            nameField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttons.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
        ])
    }

    // MARK: - Validation

    /// Normalize user input into a valid http(s) URL, or nil if it can't be one.
    /// Accepts a bare host ("app.slack.com") or a full URL; coerces a missing or
    /// `http` scheme to `https`; rejects empty, non-http(s), or hostless input.
    static func normalizedURL(from raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Reject any internal whitespace/control characters. A pasted address with
        // an embedded space ("https://exa mple.com") otherwise parses into a host
        // that silently fails to load; better to flag it as invalid up front.
        guard trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              trimmed.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }

        // Prepend https:// when no scheme is present so a bare host parses with a
        // host (URL("app.slack.com") parses path-only, no host).
        let hasScheme = trimmed.range(of: "^[a-zA-Z][a-zA-Z0-9+.-]*://", options: .regularExpression) != nil
        let candidate = hasScheme ? trimmed : "https://\(trimmed)"

        guard var comps = URLComponents(string: candidate) else { return nil }
        // Upgrade http → https; reject anything else (file, ftp, javascript, data, …).
        // URLComponents preserves scheme case ("HTTP"), so normalize it first.
        comps.scheme = comps.scheme?.lowercased()
        if comps.scheme == "http" { comps.scheme = "https" }
        guard comps.scheme == "https" else { return nil }

        // Require a host of dot-separated, non-empty labels — so a bare TLD
        // (".com"), a doubled dot ("a..b"), or a trailing/leading dot is rejected
        // while real hosts ("app.slack.com", "1.2.3.4") pass.
        guard let host = comps.host, host.contains(".") else { return nil }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }) else { return nil }

        return comps.url
    }

    // Only the URL field drives validation; a keystroke in the (optional) name
    // field never changes URL validity, so re-running the regex on it is waste.
    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as? NSTextField) === urlField else { return }
        validate()
    }

    @discardableResult
    private func validate() -> URL? {
        let raw = urlField.stringValue
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            // Empty is the initial state (focus starts in the name field), so stay
            // silent — but disable Add. `addTapped` shows the hint if the user hits
            // Return with no address, so pressing the default button never no-ops
            // in stony silence.
            errorLabel.stringValue = ""
            addButton.isEnabled = false
            return nil
        }
        if let url = Self.normalizedURL(from: trimmed) {
            errorLabel.stringValue = ""
            addButton.isEnabled = true
            return url
        }
        errorLabel.stringValue = "Enter a valid web address (https)."
        addButton.isEnabled = false
        return nil
    }

    // MARK: - Actions

    @objc private func addTapped() {
        // Return with an empty address (focus starts in the name field) must not
        // silently no-op — point the user at the address field and say why.
        if urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errorLabel.stringValue = "Enter a web address (e.g. app.slack.com)."
            window.makeFirstResponder(urlField)
            return
        }
        guard let url = validate() else { return }
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        finish(Result(name: name, url: url))
    }

    @objc private func cancelTapped() {
        finish(nil)
    }
}
