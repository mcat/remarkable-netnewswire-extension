import AppKit
import RemarkableKit

/// The view shown in NetNewsWire's share sheet while an article is sent.
final class ShareViewController: NSViewController {
    private let titleLabel = NSTextField(labelWithString: "Send to reMarkable")
    private let statusLabel = NSTextField(wrappingLabelWithString: "Preparing…")
    private let progressIndicator = NSProgressIndicator()
    private let primaryButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let secondaryButton = NSButton(title: "Open Send to reMarkable", target: nil, action: nil)

    private var task: Task<Void, Never>?
    private var isFinished = false
    private var hasClosed = false

    override var nibName: NSNib.Name? { nil }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 150))

        titleLabel.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        statusLabel.font = NSFont.systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.preferredMaxLayoutWidth = 400

        progressIndicator.style = .bar
        progressIndicator.isIndeterminate = true
        progressIndicator.controlSize = .regular

        primaryButton.target = self
        primaryButton.action = #selector(primaryAction)
        primaryButton.keyEquivalent = "\u{1B}"

        secondaryButton.target = self
        secondaryButton.action = #selector(openContainingApp)
        secondaryButton.isHidden = true

        let buttons = NSStackView(views: [secondaryButton, NSView(), primaryButton])
        buttons.orientation = .horizontal
        buttons.distribution = .fill
        buttons.setHuggingPriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [titleLabel, statusLabel, progressIndicator, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 16, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            progressIndicator.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
        ])

        view = container
        preferredContentSize = container.frame.size
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        start()
    }

    // MARK: - Work

    private func start() {
        guard task == nil, let context = extensionContext else { return }
        progressIndicator.startAnimation(nil)

        task = Task { [weak self] in
            // Bind once: the progress closure runs off the main actor, and
            // Swift 6 rejects reading a captured weak variable from there.
            guard let self else { return }
            do {
                let input = try await ShareInputReader.read(from: context)
                let settings = SettingsStore().load()
                let pipeline = SendPipeline(settings: settings, tokenStore: TokenStores.forCurrentProcess())
                let result = try await pipeline.send(input) { progress in
                    Task { @MainActor in
                        self.show(progress)
                    }
                }
                self.finish(with: result)
            } catch is CancellationError {
                return
            } catch {
                self.fail(with: error)
            }
        }
    }

    private func show(_ progress: SendProgress) {
        guard !isFinished else { return }
        statusLabel.stringValue = progress.message
    }

    private func finish(with result: SendResult) {
        isFinished = true
        progressIndicator.stopAnimation(nil)
        progressIndicator.isHidden = true
        let pages = result.pageCount == 1 ? "1 page" : "\(result.pageCount) pages"
        let images = result.imageCount == 0 ? "" : (result.imageCount == 1 ? ", 1 image" : ", \(result.imageCount) images")
        statusLabel.stringValue = "Sent “\(result.name)” to your reMarkable (\(pages)\(images))."
        primaryButton.title = "Done"
        primaryButton.keyEquivalent = "\r"

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            self?.complete()
        }
    }

    private func fail(with error: Error) {
        isFinished = true
        progressIndicator.stopAnimation(nil)
        progressIndicator.isHidden = true
        statusLabel.textColor = .systemRed
        statusLabel.stringValue = error.localizedDescription
        primaryButton.title = "Close"
        primaryButton.keyEquivalent = "\r"
        if let remarkableError = error as? RemarkableError, remarkableError == .notPaired || remarkableError == .unauthorized {
            secondaryButton.isHidden = false
        }
    }

    // MARK: - Actions

    @objc private func primaryAction() {
        if isFinished, primaryButton.title == "Done" {
            complete()
        } else {
            cancel()
        }
    }

    private func complete() {
        guard !hasClosed, let context = extensionContext else { return }
        hasClosed = true
        context.completeRequest(returningItems: [], completionHandler: nil)
    }

    private func cancel() {
        task?.cancel()
        guard !hasClosed, let context = extensionContext else { return }
        hasClosed = true
        let error = NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError, userInfo: nil)
        context.cancelRequest(withError: error)
    }

    /// The share extension lives in `Send to reMarkable.app/Contents/PlugIns/`.
    @objc private func openContainingApp() {
        let appURL = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        if appURL.pathExtension == "app" {
            NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
        }
    }
}
