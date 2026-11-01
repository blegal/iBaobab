import AppKit
import DiskUsageKit
import UpdateKit
import BaobabL10n

/// Barre de menus d'iBaobab (actions envoyées au premier répondeur).
enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()

        let app = submenu(main, "iBaobab")
        app.addItem(withTitle: L("À propos d'iBaobab"), action: #selector(AppDelegate.showAbout(_:)), keyEquivalent: "")
        app.addItem(withTitle: L("Rechercher les mises à jour…"), action: #selector(Updater.checkForUpdates(_:)), keyEquivalent: "")
            .target = MainActor.assumeIsolated { Updater.shared }
        app.addItem(.separator())
        let services = NSMenu()
        app.addItem(withTitle: L("Services"), action: nil, keyEquivalent: "").submenu = services
        NSApp.servicesMenu = services
        app.addItem(.separator())
        app.addItem(withTitle: L("Masquer iBaobab"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: L("Masquer les autres"), action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
            .keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: L("Tout afficher"), action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: L("Quitter iBaobab"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let file = submenu(main, L("Fichier"))
        file.addItem(withTitle: L("Nouvel onglet"), action: #selector(AppDelegate.newWindowForTab(_:)), keyEquivalent: "t")
        file.addItem(withTitle: L("Analyser un dossier…"), action: #selector(AppDelegate.chooseFolder(_:)), keyEquivalent: "o")
        file.addItem(.separator())
        file.addItem(withTitle: L("Analyser de nouveau"), action: #selector(AnalysisViewController.rescan(_:)), keyEquivalent: "r")
        file.addItem(withTitle: L("Afficher dans le Finder"), action: #selector(AnalysisViewController.revealInFinder(_:)), keyEquivalent: "r")
            .keyEquivalentModifierMask = [.command, .option]
        file.addItem(.separator())
        file.addItem(withTitle: L("Fermer l'onglet"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        let edit = submenu(main, L("Édition"))
        edit.addItem(withTitle: L("Copier"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: L("Tout sélectionner"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let present = submenu(main, L("Présentation"))
        for style in DiskChartStyle.allCases {
            let item = present.addItem(withTitle: style.title, action: #selector(AnalysisViewController.selectStyle(_:)), keyEquivalent: "\(style.rawValue + 1)")
            item.tag = style.rawValue
        }
        present.addItem(.separator())
        present.addItem(withTitle: L("Afficher la barre d'onglets"), action: #selector(NSWindow.toggleTabBar(_:)), keyEquivalent: "")
        present.addItem(withTitle: L("Afficher tous les onglets"), action: #selector(NSWindow.toggleTabOverview(_:)), keyEquivalent: "\\")
            .keyEquivalentModifierMask = [.command, .shift]
        present.addItem(withTitle: L("Plein écran"), action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
            .keyEquivalentModifierMask = [.command, .control]

        let go = submenu(main, L("Aller"))
        go.addItem(withTitle: L("Précédent"), action: #selector(AnalysisViewController.goBack(_:)), keyEquivalent: "[")
        go.addItem(withTitle: L("Suivant"), action: #selector(AnalysisViewController.goForward(_:)), keyEquivalent: "]")
        go.addItem(withTitle: L("Dossier parent"), action: #selector(AnalysisViewController.goUp(_:)), keyEquivalent: String(Character(UnicodeScalar(NSUpArrowFunctionKey)!)))
        go.addItem(.separator())
        go.addItem(withTitle: L("Accueil"), action: #selector(AppDelegate.showHome(_:)), keyEquivalent: "h")
            .keyEquivalentModifierMask = [.command, .shift]

        let window = submenu(main, L("Fenêtre"))
        window.addItem(withTitle: L("Réduire"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: L("Zoom"), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        window.addItem(withTitle: L("Tout ramener au premier plan"), action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = window

        return main
    }

    private static func submenu(_ main: NSMenu, _ title: String) -> NSMenu {
        let menu = NSMenu(title: title)
        main.addItem(withTitle: title, action: nil, keyEquivalent: "").submenu = menu
        return menu
    }
}
