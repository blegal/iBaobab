import AppKit
import DiskUsageKit
import BaobabL10n
import QuartzCore

/// Onglet « Accueil », en listes groupées façon iOS : disques, dossiers courants, analyses récentes,
/// puis une zone où déposer un dossier (ou ouvrir le sélecteur).
final class HomeViewController: NSViewController {
    var onAnalyze: ((URL) -> Void)?
    var onChooseFolder: (() -> Void)?

    private let disksGroup = GroupView()
    private let recentsHeader = HomeViewController.sectionHeader(L("Récents"))
    private let recentsGroup = GroupView()
    private let dropZone = DropZoneView()
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    deinit { observers.forEach { $0.0.removeObserver($0.1) } }

    override func loadView() {
        let root = DropTargetView(frame: NSRect(x: 0, y: 0, width: 760, height: 680))
        root.dropZone = dropZone
        root.onDrop = { [weak self] url in self?.onAnalyze?(url) }

        let title = NSTextField(labelWithString: L("Analyser"))
        title.font = .systemFont(ofSize: 28, weight: .bold)

        let foldersGroup = GroupView()
        for url in Self.usualFolders() {
            let isHome = url == FileManager.default.homeDirectoryForCurrentUser
            let row = HomeRow(symbol: Self.symbol(for: url), tint: url.path.hasPrefix("/Applications") ? .systemIndigo : .systemBlue,
                              title: isHome ? L("Accueil") : FileManager.default.displayName(atPath: url.path))
            row.toolTip = url.path
            row.onClick = { [weak self] in self?.onAnalyze?(url) }
            foldersGroup.add(row)
        }

        dropZone.onChoose = { [weak self] in self?.onChooseFolder?() }

        let content = NSStackView(views: [title, Self.sectionHeader(L("Disques")), disksGroup, Self.sectionHeader(L("Dossiers")), foldersGroup,
                                          recentsHeader, recentsGroup, dropZone])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 6
        content.setCustomSpacing(16, after: title)
        for group in [disksGroup, foldersGroup, recentsGroup] { content.setCustomSpacing(22, after: group) }
        content.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 28, right: 24)
        content.translatesAutoresizingMaskIntoConstraints = false

        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(content)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = document
        scroll.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scroll)
        var constraints = [
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            content.topAnchor.constraint(equalTo: document.topAnchor),
            content.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            content.centerXAnchor.constraint(equalTo: document.centerXAnchor),
            content.widthAnchor.constraint(lessThanOrEqualTo: document.widthAnchor),
            content.widthAnchor.constraint(lessThanOrEqualToConstant: 680),
            dropZone.heightAnchor.constraint(equalToConstant: 92),
        ]
        // Colonne aussi large que possible dans la limite de 680 points, sans imposer sa taille à la fenêtre.
        let wide = content.widthAnchor.constraint(equalTo: document.widthAnchor)
        wide.priority = NSLayoutConstraint.Priority(NSLayoutConstraint.Priority.windowSizeStayPut.rawValue - 1)
        constraints.append(wide)
        for view in [title, disksGroup, foldersGroup, recentsGroup, dropZone] as [NSView] {
            constraints.append(view.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -48))
        }
        NSLayoutConstraint.activate(constraints)
        view = root
        reloadDisks()
        reloadRecents()

        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            observers.append((workspace, workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.reloadDisks() }))
        }
        observers.append((.default, NotificationCenter.default.addObserver(forName: RecentAnalyses.changed, object: nil, queue: .main) { [weak self] _ in
            self?.reloadRecents()
        }))
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        // L'espace libre a pu changer depuis la dernière visite.
        reloadDisks()
        reloadRecents()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // Les jauges des disques se remplissent, l'une après l'autre.
        guard Animations.isOn(.gauges) else { return }
        for (index, row) in disksGroup.rows.enumerated() { row.animateBar(delay: Double(index) * 0.12) }
    }

    private static func sectionHeader(_ title: String) -> NSView {
        let label = NSTextField(labelWithString: title.uppercased())
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        let box = NSStackView(views: [label])
        box.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 0)
        return box
    }

    // MARK: Disques

    private static let volumeKeys: [URLResourceKey] = [.volumeLocalizedNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
                                                       .volumeIsInternalKey, .volumeIsRemovableKey, .volumeIsLocalKey]

    private func reloadDisks() {
        disksGroup.removeAll()
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Self.volumeKeys, options: [.skipHiddenVolumes]) ?? []
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: Set(Self.volumeKeys)) else { continue }
            let total = Int64(values.volumeTotalCapacity ?? 0)
            let free = Format.availableCapacity(at: url) ?? Int64(values.volumeAvailableCapacity ?? 0)
            let isInternal = values.volumeIsInternal == true, local = values.volumeIsLocal != false
            let symbol = !local ? "network" : isInternal ? "internaldrive" : "externaldrive"
            let tint: NSColor = !local ? .systemTeal : isInternal ? .systemGray : .systemOrange
            let row = HomeRow(symbol: symbol, tint: tint, title: values.volumeLocalizedName ?? url.displayName)
            if total > 0 {
                row.trailing = L("\(Format.size(free)) libres sur \(Format.size(total))")
                row.fraction = Double(total - free) / Double(total)
            }
            row.toolTip = url.path
            row.onClick = { [weak self] in self?.onAnalyze?(url) }
            disksGroup.add(row)
        }
    }

    // MARK: Récents

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.locale = Locale(identifier: Bundle.main.preferredLocalizations.first == "fr" ? "fr_FR" : "en_US")
        return formatter
    }()

    private func reloadRecents() {
        recentsGroup.removeAll()
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let entries = RecentAnalyses.entries
        for entry in entries {
            let url = entry.url
            let parent = url.deletingLastPathComponent().path
            let place = parent.hasPrefix(home) ? "~" + parent.dropFirst(home.count) : parent
            let row = HomeRow(symbol: "clock", tint: nil, title: url.displayName)
            let when = Date().timeIntervalSince(entry.date) < 60 ? L("à l'instant") : Self.relativeFormatter.localizedString(for: entry.date, relativeTo: Date())
            row.subtitle = "\(place) · \(when)"
            row.trailing = Format.size(entry.size)
            row.toolTip = url.path
            row.onClick = { [weak self] in self?.onAnalyze?(url) }
            row.menuProvider = {
                let menu = NSMenu()
                menu.addItem(ClosureItem(L("Afficher dans le Finder")) { NSWorkspace.shared.activateFileViewerSelecting([url]) })
                menu.addItem(.separator())
                menu.addItem(ClosureItem(L("Retirer de l'historique")) { RecentAnalyses.remove(url) })
                menu.addItem(ClosureItem(L("Effacer l'historique")) { RecentAnalyses.clear() })
                return menu
            }
            recentsGroup.add(row)
        }
        recentsHeader.isHidden = entries.isEmpty
        recentsGroup.isHidden = entries.isEmpty
    }

    // MARK: Dossiers usuels

    private static func usualFolders() -> [URL] {
        let manager = FileManager.default
        let home = manager.homeDirectoryForCurrentUser
        let directories: [FileManager.SearchPathDirectory] = [.desktopDirectory, .documentDirectory, .downloadsDirectory, .picturesDirectory]
        var urls = [home] + directories.compactMap { manager.urls(for: $0, in: .userDomainMask).first }
        urls += [home.appendingPathComponent("Library"), URL(fileURLWithPath: "/Applications")]
        return urls.filter { url in
            var isDirectory: ObjCBool = false
            return manager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }

    private static func symbol(for url: URL) -> String {
        switch url.lastPathComponent {
        case "Desktop": "menubar.dock.rectangle"
        case "Documents": "doc"
        case "Downloads": "arrow.down.circle"
        case "Pictures": "photo"
        case "Library": "building.columns"
        case "Applications": "square.grid.2x2"
        default: url == FileManager.default.homeDirectoryForCurrentUser ? "house" : "folder"
        }
    }
}

// MARK: - Liste groupée

/// Couleurs « groupées » d'iOS, claires et sombres.
private enum Palette {
    static let ground = NSColor(name: nil) { $0.isDark ? NSColor(white: 0.11, alpha: 1) : NSColor(srgbRed: 0.949, green: 0.949, blue: 0.969, alpha: 1) }
    static let card = NSColor(name: nil) { $0.isDark ? NSColor(white: 0.17, alpha: 1) : .white }
    static let pressed = NSColor(name: nil) { $0.isDark ? NSColor(white: 0.24, alpha: 1) : NSColor(white: 0.9, alpha: 1) }
}

private extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}

/// Carte blanche à coins arrondis qui empile des lignes séparées par un filet.
private final class GroupView: NSView {
    private let stack = NSStackView()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        stack.orientation = .vertical
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        Palette.card.setFill()
        bounds.fill()
    }

    func add(_ row: HomeRow) {
        (stack.arrangedSubviews.last as? HomeRow)?.showsSeparator = true
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    func removeAll() { stack.arrangedSubviews.forEach { $0.removeFromSuperview() } }

    var rows: [HomeRow] { stack.arrangedSubviews.compactMap { $0 as? HomeRow } }
}

/// Ligne cliquable : pastille colorée (ou symbole gris), titre, sous-titre, texte à droite, barre et chevron facultatifs.
private final class HomeRow: NSView {
    var onClick: (() -> Void)?
    var menuProvider: (() -> NSMenu)?
    var showsSeparator = false { didSet { needsDisplay = true } }
    var subtitle = "" { didSet { subtitleLabel.stringValue = subtitle; subtitleLabel.isHidden = subtitle.isEmpty } }
    var trailing = "" { didSet { trailingLabel.stringValue = trailing } }
    var fraction: Double? { didSet { bar.fraction = fraction ?? 0; bar.isHidden = fraction == nil } }

    private let subtitleLabel = NSTextField(labelWithString: "")
    private let trailingLabel = NSTextField(labelWithString: "")
    private let bar = UsageBar()
    private let textInset: CGFloat
    private var highlighted = false { didSet { needsDisplay = true } }

    init(symbol: String, tint: NSColor?, title: String) {
        textInset = tint == nil ? 50 : 56
        super.init(frame: .zero)
        let icon = SymbolTile(symbol: symbol, tint: tint)
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 14)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.setContentHuggingPriority(.init(1), for: .horizontal)
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingMiddle
        subtitleLabel.isHidden = true
        trailingLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        trailingLabel.textColor = .secondaryLabelColor
        trailingLabel.setContentHuggingPriority(.required, for: .horizontal)
        bar.isHidden = true
        bar.heightAnchor.constraint(equalToConstant: 5).isActive = true

        let titleRow = NSStackView(views: [titleLabel, trailingLabel])
        titleRow.distribution = .fill
        let texts = NSStackView(views: [titleRow, subtitleLabel, bar])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 4
        titleRow.widthAnchor.constraint(equalTo: texts.widthAnchor).isActive = true
        bar.widthAnchor.constraint(equalTo: texts.widthAnchor).isActive = true
        let chevron = NSImageView(image: NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil) ?? NSImage())
        chevron.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
        chevron.contentTintColor = .tertiaryLabelColor
        let row = NSStackView(views: [icon, texts, chevron])
        row.spacing = 12
        row.distribution = .fill
        row.edgeInsets = NSEdgeInsets(top: 9, left: 14, bottom: 9, right: 14)
        texts.setContentHuggingPriority(.init(1), for: .horizontal)
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func mouseDown(with event: NSEvent) { highlighted = true }

    override func mouseUp(with event: NSEvent) {
        highlighted = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }

    func animateBar(delay: Double) {
        if fraction != nil { bar.animate(delay: delay) }
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        if highlighted {
            Palette.pressed.setFill()
            bounds.fill()
        }
        if showsSeparator {
            NSColor.separatorColor.setFill()
            NSRect(x: textInset, y: 0, width: bounds.width - textInset, height: 1 / max(1, window?.backingScaleFactor ?? 2)).fill()
        }
    }
}

/// Pastille iOS : carré arrondi coloré et symbole blanc ; sans couleur, un symbole gris seul.
private final class SymbolTile: NSView {
    private let symbol: String
    private let tint: NSColor?

    init(symbol: String, tint: NSColor?) {
        self.symbol = symbol
        self.tint = tint
        super.init(frame: .zero)
        let side: CGFloat = tint == nil ? 24 : 30
        widthAnchor.constraint(equalToConstant: side).isActive = true
        heightAnchor.constraint(equalToConstant: side).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        if let tint {
            tint.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
        }
        let configuration = NSImage.SymbolConfiguration(pointSize: tint == nil ? 15 : 14, weight: .medium)
            .applying(.init(paletteColors: [tint == nil ? .secondaryLabelColor : .white]))
        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) else { return }
        let size = image.size
        image.draw(in: NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height))
    }
}

/// Barre d'occupation fine : accentuée, orange au-delà de 80 %, rouge au-delà de 90 %.
/// Peut se remplir depuis zéro (effet « jauges ») ; l'horloge d'affichage ne tourne que pendant ce temps.
private final class UsageBar: NSView {
    var fraction = 0.0 { didSet { needsDisplay = true } }
    /// Valeur affichée pendant l'animation (nil au repos : `fraction`).
    private var shown: Double?
    private var link: CADisplayLink?
    private var start: CFTimeInterval = 0

    func animate(delay: Double) {
        link?.invalidate()
        shown = 0
        start = CACurrentMediaTime() + delay
        let link = displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        needsDisplay = true
    }

    @objc private func tick(_ link: CADisplayLink) {
        let q = min(1, max(0, (CACurrentMediaTime() - start) / 0.9))
        shown = fraction * (1 - pow(1 - q, 3))
        if q >= 1 {
            shown = nil
            link.invalidate()
            self.link = nil
        }
        needsDisplay = true
    }

    override func removeFromSuperview() {
        link?.invalidate()
        link = nil
        super.removeFromSuperview()
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        let value = min(1, max(0, shown ?? fraction))
        guard value > 0.001 else { return }
        let color: NSColor = value > 0.9 ? .systemRed : value > 0.8 ? .systemOrange : .controlAccentColor
        color.setFill()
        let width = max(bounds.height, bounds.width * CGFloat(value))
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: width, height: bounds.height), xRadius: radius, yRadius: radius).fill()
    }
}

// MARK: - Dépôt

/// Zone en pointillés : « Déposez un dossier ici, ou » et le bouton du sélecteur ; accentuée pendant un glisser.
private final class DropZoneView: NSView {
    var onChoose: (() -> Void)?
    var isTargeted = false { didSet { needsDisplay = true } }
    /// Effet « dépôt magnétique » : de 0 à 1 à l'approche d'un dossier glissé (halo et bordure accentués).
    var glow: CGFloat = 0 {
        didSet {
            guard glow != oldValue else { return }
            layer?.shadowColor = NSColor.controlAccentColor.cgColor
            layer?.shadowOffset = .zero
            layer?.shadowRadius = 16 * glow
            layer?.shadowOpacity = Float(0.9 * glow)
            needsDisplay = true
        }
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        let icon = NSImageView(image: NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 18, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor
        let label = NSTextField(labelWithString: L("Déposez un dossier ici, ou"))
        label.textColor = .secondaryLabelColor
        let button = NSButton(title: L("Choisir un dossier…"), target: self, action: #selector(choose(_:)))
        button.bezelStyle = .push
        button.keyEquivalent = "\r"
        button.controlSize = .large
        let row = NSStackView(views: [icon, label, button])
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.centerXAnchor.constraint(equalTo: centerXAnchor),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            row.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 12),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func choose(_ sender: Any?) { onChoose?() }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 12, yRadius: 12)
        let accent = max(isTargeted ? 1 : 0, glow)
        if accent > 0 {
            if glow > 0 {
                NSColor.controlBackgroundColor.setFill()
                path.fill()
            }
            NSColor.controlAccentColor.withAlphaComponent(0.06 + 0.08 * glow).setFill()
            path.fill()
        }
        path.lineWidth = 1.5 + glow
        path.setLineDash([6, 4], count: 2, phase: 0)
        (accent > 0 ? NSColor.controlAccentColor.withAlphaComponent(0.55 + 0.45 * accent) : NSColor.tertiaryLabelColor).setStroke()
        path.stroke()
    }

    /// Onde lumineuse au dépôt : trois cercles partent du centre (Core Animation, puis retirés).
    func ripple() {
        guard let layer else { return }
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius = max(bounds.width, bounds.height) * 0.55
        for index in 0..<3 {
            let ring = CAShapeLayer()
            ring.frame = bounds
            ring.fillColor = nil
            ring.strokeColor = NSColor.controlAccentColor.cgColor
            ring.lineWidth = 2
            ring.opacity = 0
            layer.addSublayer(ring)
            let small = CGPath(ellipseIn: CGRect(x: center.x - 10, y: center.y - 10, width: 20, height: 20), transform: nil)
            let large = CGPath(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2), transform: nil)
            let grow = CABasicAnimation(keyPath: "path")
            grow.fromValue = small
            grow.toValue = large
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            let group = CAAnimationGroup()
            group.animations = [grow, fade]
            group.duration = 0.9
            group.beginTime = CACurrentMediaTime() + Double(index) * 0.15
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            CATransaction.begin()
            CATransaction.setCompletionBlock { ring.removeFromSuperlayer() }
            ring.add(group, forKey: "ripple")
            CATransaction.commit()
        }
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Vue racine : fond groupé ; accepte le dépôt d'un dossier n'importe où et l'indique dans la zone de dépôt.
private final class DropTargetView: NSView {
    var onDrop: ((URL) -> Void)?
    weak var dropZone: DropZoneView?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        Palette.ground.setFill()
        dirtyRect.fill()
    }

    private func folder(in info: NSDraggingInfo) -> URL? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
        return urls.first { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
    }

    private var accepts = false

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        accepts = folder(in: sender) != nil
        dropZone?.isTargeted = accepts
        return draggingUpdated(sender)
    }

    /// Dépôt magnétique : la zone s'illumine à mesure que le dossier s'en approche.
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if accepts, Animations.isOn(.magneticDrop), let zone = dropZone {
            let point = zone.convert(sender.draggingLocation, from: nil)
            let dx = max(zone.bounds.minX - point.x, 0, point.x - zone.bounds.maxX)
            let dy = max(zone.bounds.minY - point.y, 0, point.y - zone.bounds.maxY)
            zone.glow = max(0, 1 - hypot(dx, dy) / 320)
        }
        return accepts ? .generic : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropZone?.isTargeted = false
        dropZone?.glow = 0
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        // Le dossier glissé est aspiré vers le centre de la zone (animation de dépôt d'AppKit).
        if Animations.isOn(.magneticDrop) { sender.animatesToDestination = true }
        return true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropZone?.isTargeted = false
        guard let url = folder(in: sender) else { dropZone?.glow = 0; return false }
        guard Animations.isOn(.magneticDrop), let zone = dropZone else {
            dropZone?.glow = 0
            onDrop?(url)
            return true
        }
        let center = convert(CGPoint(x: zone.bounds.midX, y: zone.bounds.midY), from: zone)
        sender.enumerateDraggingItems(options: [], for: self, classes: [NSURL.self], searchOptions: [:]) { item, _, _ in
            item.draggingFrame = CGRect(x: center.x - 8, y: center.y - 8, width: 16, height: 16)
        }
        zone.glow = 1
        zone.ripple()
        // L'analyse s'ouvre une fois l'onde partie, pour qu'on la voie.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self, weak zone] in
            zone?.glow = 0
            self?.onDrop?(url)
        }
        return true
    }
}

/// Élément de menu qui exécute une fermeture.
private final class ClosureItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run(_:)), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func run(_ sender: Any?) { handler() }
}
