import AppKit
import BaobabL10n
import DiskUsageKit

/// Niveau d'animation, comme dans iExplorer : chaque niveau inclut les effets des précédents.
enum AnimationLevel: Int, CaseIterable {
    case none, light, full, wow

    var title: String {
        switch self {
        case .none: L("Sans animation")
        case .light: L("Animations légères")
        case .full: L("Animations complètes")
        case .wow: L("Whaouh+++")
        }
    }

    /// Titre court d'un groupe d'effets.
    var groupTitle: String {
        switch self {
        case .none: L("Sans animation")
        case .light: L("Légères")
        case .full: L("Complètes")
        case .wow: L("Whaouh+++")
        }
    }
}

/// Les effets d'iBaobab ; ceux du graphique sont joués par DiskUsageKit (même nom que `DiskEffect`).
enum AnimationEffect: String, CaseIterable {
    case growth, zoom, gauges
    case unfold, morph, crumble, liveScan
    case baobab, leaves, magneticDrop

    var level: AnimationLevel {
        switch self {
        case .growth, .zoom, .gauges: .light
        case .unfold, .morph, .crumble, .liveScan: .full
        case .baobab, .leaves, .magneticDrop: .wow
        }
    }

    var title: String {
        switch self {
        case .growth: L("Le graphique se construit à la fin d'une analyse")
        case .zoom: L("Zoom en entrant dans un dossier ou en remontant")
        case .gauges: L("Les jauges des disques se remplissent sur l'accueil")
        case .unfold: L("Les anneaux du soleil se déploient")
        case .morph: L("Les blocs glissent d'une représentation à l'autre")
        case .crumble: L("Le bloc mis à la corbeille s'effrite")
        case .liveScan: L("Les dossiers apparaissent pendant l'analyse")
        case .baobab: L("Un baobab pousse à la fin d'une analyse")
        case .leaves: L("Pluie de feuilles après avoir libéré plus d'1 Go")
        case .magneticDrop: L("La zone de dépôt aspire le dossier glissé")
        }
    }
}

enum Animations {
    static let changed = Notification.Name("AnimationsChanged")
    private static let levelKey = "animationLevel"
    private static let disabledKey = "disabledAnimationEffects"

    /// Niveau choisi (Animations légères par défaut).
    static var level: AnimationLevel {
        get { AnimationLevel(rawValue: UserDefaults.standard.object(forKey: levelKey) as? Int ?? 1) ?? .light }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: levelKey)
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    /// Effets décochés dans les réglages.
    static var disabled: Set<AnimationEffect> {
        get { Set((UserDefaults.standard.stringArray(forKey: disabledKey) ?? []).compactMap(AnimationEffect.init(rawValue:))) }
        set {
            UserDefaults.standard.set(newValue.map(\.rawValue).sorted(), forKey: disabledKey)
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    /// macOS demande-t-il de réduire les animations ? Aucun effet ne joue alors.
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    static func isOn(_ effect: AnimationEffect) -> Bool {
        !reduceMotion && level.rawValue >= effect.level.rawValue && !disabled.contains(effect)
    }

    /// Branche les effets du graphique (DiskUsageKit) sur les réglages de l'app.
    @MainActor static func install() {
        DiskEffects.isEnabled = { effect in AnimationEffect(rawValue: effect.rawValue).map(isOn) ?? false }
    }
}

// MARK: - Réglages

/// Fenêtre Réglages : le niveau, puis un interrupteur par effet, rangés par niveau.
final class AnimationSettingsWindowController: NSWindowController {
    static let shared = AnimationSettingsWindowController()

    private let levelPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var switches: [AnimationEffect: NSSwitch] = [:]
    private var rows: [AnimationEffect: NSView] = [:]
    private let reduceMotionNote = NSTextField(wrappingLabelWithString: L("« Réduire les animations » est activé dans les réglages d'accessibilité de macOS : aucune animation n'est jouée."))
    private var observer: NSObjectProtocol?

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 520), styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.title = L("Réglages")
        super.init(window: window)

        for level in AnimationLevel.allCases { levelPopup.addItem(withTitle: level.title) }
        levelPopup.target = self
        levelPopup.action = #selector(levelChanged(_:))
        let levelLabel = NSTextField(labelWithString: L("Niveau :"))
        let levelRow = NSStackView(views: [levelLabel, levelPopup])
        levelRow.spacing = 8

        let intro = NSTextField(wrappingLabelWithString: L("Le niveau active tous les effets jusqu'à lui ; décochez ceux que vous ne voulez pas. Les effets ne jouent qu'au moment d'une action : au repos, rien ne tourne."))
        intro.textColor = .secondaryLabelColor
        intro.font = .systemFont(ofSize: 12)
        reduceMotionNote.textColor = .systemOrange
        reduceMotionNote.font = .systemFont(ofSize: 12)

        var views: [NSView] = [levelRow, intro, reduceMotionNote]
        var headers: [NSView] = []
        for level in [AnimationLevel.light, .full, .wow] {
            let header = NSTextField(labelWithString: level.groupTitle.uppercased())
            header.font = .systemFont(ofSize: 11, weight: .semibold)
            header.textColor = .secondaryLabelColor
            views.append(header)
            headers.append(header)
            for effect in AnimationEffect.allCases where effect.level == level {
                let toggle = NSSwitch()
                toggle.controlSize = .small
                toggle.target = self
                toggle.action = #selector(effectToggled(_:))
                toggle.identifier = NSUserInterfaceItemIdentifier(effect.rawValue)
                let label = NSTextField(labelWithString: effect.title)
                label.lineBreakMode = .byTruncatingTail
                label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                let row = NSStackView(views: [toggle, label])
                row.spacing = 10
                switches[effect] = toggle
                rows[effect] = row
                views.append(row)
            }
        }
        let content = NSStackView(views: views)
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 8
        for header in headers { content.setCustomSpacing(4, after: header) }
        content.setCustomSpacing(14, after: levelRow)
        content.edgeInsets = NSEdgeInsets(top: 20, left: 22, bottom: 22, right: 22)
        intro.preferredMaxLayoutWidth = 436
        reduceMotionNote.preferredMaxLayoutWidth = 436
        window.contentView = content
        window.center()

        observer = NotificationCenter.default.addObserver(forName: Animations.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func refresh() {
        let level = Animations.level
        levelPopup.selectItem(at: level.rawValue)
        let disabled = Animations.disabled
        for (effect, toggle) in switches {
            let available = effect.level.rawValue <= level.rawValue
            toggle.isEnabled = available
            toggle.state = available && !disabled.contains(effect) ? .on : .off
            rows[effect]?.alphaValue = available ? 1 : 0.45
        }
        reduceMotionNote.isHidden = !Animations.reduceMotion
    }

    @objc private func levelChanged(_ sender: NSPopUpButton) {
        Animations.level = AnimationLevel(rawValue: sender.indexOfSelectedItem) ?? .light
    }

    @objc private func effectToggled(_ sender: NSSwitch) {
        guard let raw = sender.identifier?.rawValue, let effect = AnimationEffect(rawValue: raw) else { return }
        var disabled = Animations.disabled
        if sender.state == .on { disabled.remove(effect) } else { disabled.insert(effect) }
        Animations.disabled = disabled
    }
}
