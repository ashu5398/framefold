import AppKit

/// One square tile: aspect-filled thumbnail, iCloud/video/pending badges and a selection ring.
final class PhotoCell: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("PhotoCell")

    private let imageLayer = CALayer()
    private let selectionLayer = CALayer()
    private let shadeLayer = CAGradientLayer()
    private let cloudBadge = NSImageView()
    private let statusBadge = NSImageView()
    private let durationLabel = NSTextField(labelWithString: "")
    private let checkmark = NSImageView()
    private let bestLabel = NSTextField(labelWithString: "Keep")
    private var currentID: String?
    private var isPendingDelete = false

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        root.layer?.masksToBounds = true

        imageLayer.contentsGravity = .resizeAspectFill
        imageLayer.masksToBounds = true
        root.layer?.addSublayer(imageLayer)

        shadeLayer.colors = [NSColor.black.withAlphaComponent(0).cgColor, NSColor.black.withAlphaComponent(0.45).cgColor]
        shadeLayer.startPoint = CGPoint(x: 0.5, y: 0.65)
        shadeLayer.endPoint = CGPoint(x: 0.5, y: 0)
        root.layer?.addSublayer(shadeLayer)

        selectionLayer.borderColor = NSColor.controlAccentColor.cgColor
        selectionLayer.borderWidth = 3
        selectionLayer.isHidden = true
        root.layer?.addSublayer(selectionLayer)

        for badge in [cloudBadge, statusBadge, checkmark] {
            badge.translatesAutoresizingMaskIntoConstraints = false
            badge.imageScaling = .scaleProportionallyUpOrDown
            badge.shadow = Self.badgeShadow
            root.addSubview(badge)
        }
        durationLabel.translatesAutoresizingMaskIntoConstraints = false
        durationLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        durationLabel.textColor = .white
        durationLabel.shadow = Self.badgeShadow
        root.addSubview(durationLabel)

        bestLabel.translatesAutoresizingMaskIntoConstraints = false
        bestLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        bestLabel.textColor = .white
        bestLabel.alignment = .center
        bestLabel.wantsLayer = true
        bestLabel.drawsBackground = true
        bestLabel.backgroundColor = .systemGreen
        bestLabel.layer?.cornerRadius = 4
        bestLabel.layer?.masksToBounds = true
        root.addSubview(bestLabel)

        checkmark.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Selected")?
            .withSymbolConfiguration(.init(paletteColors: [.white, .controlAccentColor]))

        NSLayoutConstraint.activate([
            cloudBadge.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 6),
            cloudBadge.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -5),
            cloudBadge.widthAnchor.constraint(equalToConstant: 16),
            cloudBadge.heightAnchor.constraint(equalToConstant: 14),

            durationLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -6),
            durationLabel.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -4),

            statusBadge.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 6),
            statusBadge.topAnchor.constraint(equalTo: root.topAnchor, constant: 6),
            statusBadge.widthAnchor.constraint(equalToConstant: 15),
            statusBadge.heightAnchor.constraint(equalToConstant: 15),

            checkmark.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -6),
            checkmark.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -6),
            checkmark.widthAnchor.constraint(equalToConstant: 20),
            checkmark.heightAnchor.constraint(equalToConstant: 20),

            bestLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -6),
            bestLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 6),
            bestLabel.widthAnchor.constraint(equalToConstant: 36),
        ])
        view = root
    }

    private static let badgeShadow: NSShadow = {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = .zero
        return shadow
    }()

    override func viewDidLayout() {
        super.viewDidLayout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = view.bounds
        shadeLayer.frame = view.bounds
        selectionLayer.frame = view.bounds
        CATransaction.commit()
    }

    override var isSelected: Bool {
        didSet { updateSelection() }
    }

    override var highlightState: NSCollectionViewItem.HighlightState {
        didSet { updateSelection() }
    }

    private func updateSelection() {
        let on = isSelected || highlightState == .forSelection
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.15)
        selectionLayer.isHidden = !on
        imageLayer.opacity = isPendingDelete ? 0.45 : on ? 0.85 : 1
        CATransaction.commit()
        checkmark.isHidden = !on
        if on { durationLabel.isHidden = true } else { durationLabel.isHidden = durationLabel.stringValue.isEmpty }
    }

    func configure(item: PhotoItem, showCloud: Bool, isBest: Bool, compact: Bool, copyMode: Bool, thumbnailURL: URL) {
        let changed = currentID != item.id
        currentID = item.id
        if changed { imageLayer.contents = nil }
        isPendingDelete = item.pendingDeviceDelete
        ThumbnailCache.shared.load(item.id, url: thumbnailURL) { [weak self] image in
            guard let self, self.currentID == item.id, let image else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(!changed)
            self.imageLayer.contents = image
            CATransaction.commit()
        }

        // Badges are noise on the tiny Years tiles.
        let small = compact
        if showCloud && !small && item.cloud != .unknown {
            let inCloud = item.cloud == .inCloud
            cloudBadge.image = NSImage(systemSymbolName: inCloud ? "icloud.fill" : "icloud.slash.fill",
                                       accessibilityDescription: inCloud ? "In iCloud" : "Not in iCloud")?
                .withSymbolConfiguration(.init(paletteColors: [inCloud ? .white : .systemOrange]))
            cloudBadge.toolTip = inCloud ? "In iCloud Photos" : "Not in iCloud Photos"
            cloudBadge.isHidden = false
        } else {
            cloudBadge.isHidden = true
        }

        if !small && item.pendingDeviceDelete {
            statusBadge.image = NSImage(systemSymbolName: "trash.circle.fill", accessibilityDescription: "Waiting to delete")?
                .withSymbolConfiguration(.init(paletteColors: [.white, .systemRed]))
            statusBadge.toolTip = "Will be deleted from the iPhone when it connects"
            statusBadge.isHidden = false
        } else if !small && copyMode && item.isFromDevice && !item.isCopied {
            statusBadge.image = NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: "Not copied yet")?
                .withSymbolConfiguration(.init(paletteColors: [.white]))
            statusBadge.toolTip = "On the iPhone, not copied to this Mac yet"
            statusBadge.isHidden = false
        } else {
            statusBadge.isHidden = true
        }

        if let duration = item.duration, item.isVideo, !small {
            let total = Int(duration.rounded())
            durationLabel.stringValue = String(format: "%d:%02d", total / 60, total % 60)
        } else if let frames = item.burstCount, !small {
            durationLabel.stringValue = "Burst · \(frames)"
        } else {
            durationLabel.stringValue = ""
        }
        shadeLayer.isHidden = small || (cloudBadge.isHidden && durationLabel.stringValue.isEmpty)
        bestLabel.isHidden = !isBest
        view.toolTip = [item.fileName, item.category].compactMap { $0 }.joined(separator: " · ")
        updateSelection()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        imageLayer.contents = nil
        currentID = nil
    }
}

/// Sticky section header with the date range and item count.
final class SectionHeader: NSView, NSCollectionViewElement {
    static let identifier = NSUserInterfaceItemIdentifier("SectionHeader")

    private let background = NSVisualEffectView()
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let chevron = NSButton()
    /// Called with whether ⌥ was held, which folds or unfolds every section.
    var onToggle: ((Bool) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        background.material = .headerView
        background.blendingMode = .withinWindow
        background.state = .followsWindowActiveState
        background.translatesAutoresizingMaskIntoConstraints = false
        addSubview(background)

        chevron.isBordered = false
        chevron.imagePosition = .imageOnly
        chevron.contentTintColor = .secondaryLabelColor
        chevron.target = self
        chevron.action = #selector(toggle)
        chevron.toolTip = "Collapse or expand (⌥-click for all)"
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.widthAnchor.constraint(equalToConstant: 16).isActive = true

        let stack = NSStackView(views: [chevron, title, subtitle])
        stack.orientation = .horizontal
        stack.alignment = .firstBaseline
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        subtitle.textColor = .secondaryLabelColor
        subtitle.font = .systemFont(ofSize: 12)

        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(title text: String, subtitle sub: String, scale: TimeScale, collapsed: Bool) {
        title.stringValue = text
        subtitle.stringValue = sub
        title.font = scale == .years ? .systemFont(ofSize: 22, weight: .bold) : .systemFont(ofSize: 15, weight: .semibold)
        chevron.image = NSImage(systemSymbolName: collapsed ? "chevron.right" : "chevron.down",
                                accessibilityDescription: collapsed ? "Expand" : "Collapse")?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        setAccessibilityLabel("\(text), \(collapsed ? "collapsed" : "expanded")")
    }

    @objc private func toggle() {
        onToggle?(NSEvent.modifierFlags.contains(.option))
    }

    // Keep the click from starting the grid's rubber-band selection, so mouseUp arrives here.
    override func mouseDown(with event: NSEvent) {}

    // A click anywhere on the header folds it too.
    override func mouseUp(with event: NSEvent) {
        guard event.clickCount == 1 else { return }
        onToggle?(event.modifierFlags.contains(.option))
    }
}
