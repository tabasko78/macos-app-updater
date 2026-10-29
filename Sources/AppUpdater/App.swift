import SwiftUI
import Combine

struct AppUpdaterApp: App {
    @NSApplicationDelegateAdaptor(Delegue.self) private var delegue

    // Tout est tenu par le Delegue (icône de la barre des menus, panneau, fenêtre) : SwiftUI exige
    // seulement une scène, celle-ci n'affiche rien.
    var body: some Scene {
        Settings { EmptyView() }
    }
}

/// Icône de la barre des menus : clic gauche, la fenêtre ; clic droit, le panneau.
/// La fenêtre ouverte, le panneau se ferme.
@MainActor
final class Delegue: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let moteur = Moteur()
    private var icone: NSStatusItem!
    private let panneau = NSPopover()
    private var fenetre: NSWindow?
    private var abonnement: AnyCancellable?
    private var abonnementHauteur: AnyCancellable?

    func applicationDidFinishLaunching(_ n: Notification) {
        moteur.montrerFenetre = { [weak self] in self?.montrerFenetre() }
        moteur.appliquerAffichage = { [weak self] in self?.appliquerAffichage() }

        icone = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        icone.button?.target = self
        icone.button?.action = #selector(clic)
        icone.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        icone.button?.imagePosition = .imageLeading

        panneau.behavior = .transient
        let hote = NSHostingController(rootView: PanneauMenu().environmentObject(moteur))
        hote.sizingOptions = .preferredContentSize
        panneau.contentViewController = hote

        abonnement = moteur.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.majIcone() }
        }
        majIcone()
        appliquerAffichage()
        // La fenêtre suit la hauteur de son contenu (au plus 30 lignes, puis la liste défile).
        abonnementHauteur = moteur.$hauteurFenetre
            .removeDuplicates()
            .debounce(for: .milliseconds(80), scheduler: RunLoop.main)
            .sink { [weak self] h in self?.ajusterHauteur(h) }
        if CommandLine.arguments.contains("--fenetre") { montrerFenetre() }
    }

    /// Double-clic sur l'app alors qu'elle tourne déjà : la fenêtre.
    func applicationShouldHandleReopen(_ s: NSApplication, hasVisibleWindows: Bool) -> Bool {
        montrerFenetre()
        return false
    }

    /// Réglages > Afficher l'app dans : l'icône de la barre des menus, celle du Dock, ou les deux.
    /// En « Barre des menus » seule, l'app ne passe dans le Dock que le temps que la fenêtre est ouverte.
    private func appliquerAffichage() {
        let a = moteur.affichage
        icone.isVisible = a.menu
        let fenetreOuverte = fenetre?.isVisible ?? false
        NSApp.setActivationPolicy(a.dock || fenetreOuverte ? .regular : .accessory)
        majIcone()
    }

    private func majIcone() {
        let n = moteur.aMettreAJour.count
        icone.button?.image = NSImage(systemSymbolName: n > 0 ? "arrow.down.app.fill" : "arrow.down.app", accessibilityDescription: L.t("Mises à jour", "App Updater"))
        icone.button?.title = n > 0 ? " \(n)" : ""
        // Pastille rouge sur l'icône du Dock, quand elle y est.
        NSApp.dockTile.badgeLabel = moteur.affichage.dock && n > 0 ? "\(n)" : nil
    }

    @objc private func clic() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            if panneau.isShown { panneau.performClose(nil) }
            else if let b = icone.button { panneau.show(relativeTo: b.bounds, of: b, preferredEdge: .minY) }
        } else {
            montrerFenetre()
        }
    }

    func montrerFenetre() {
        panneau.performClose(nil)
        if fenetre == nil {
            let hote = NSHostingController(rootView: FenetreListe().environmentObject(moteur))
            hote.sizingOptions = []   // c'est ajusterHauteur qui décide de la taille, pas SwiftUI
            let f = NSWindow(contentViewController: hote)
            f.minSize = NSSize(width: 820, height: 260)
            f.title = L.t("Mises à jour", "App Updater")
            // Pas de barre de titre système : le fond de l'app monte jusqu'en haut, seuls les trois boutons restent.
            f.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            f.titlebarAppearsTransparent = true
            f.titleVisibility = .hidden
            f.isMovableByWindowBackground = true
            f.isReleasedWhenClosed = false
            f.delegate = self
            f.setContentSize(NSSize(width: 980, height: 720))
            f.center()
            f.setFrameAutosaveName("FenetrePrincipale")
            fenetre = f
        }
        // Le temps que la fenêtre est ouverte, l'app devient ordinaire (Dock, Cmd-Tab) et reste devant quand on s'en sert.
        NSApp.setActivationPolicy(.regular)
        fenetre?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        ajusterHauteur(moteur.hauteurFenetre)   // la hauteur a pu être mesurée avant que la fenêtre existe
    }

    /// Garde le haut de la fenêtre en place et fait monter ou descendre le bas, sans sortir de l'écran.
    private func ajusterHauteur(_ contenu: CGFloat) {
        guard let f = fenetre, contenu > 0 else { return }
        let barre = f.frame.height - f.contentLayoutRect.height   // barre de titre transparente
        let ecran = (f.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        let voulue = min(max(contenu + barre, f.minSize.height), ecran.height - 20)
        guard abs(voulue - f.frame.height) > 1 else { return }
        var cadre = f.frame
        cadre.origin.y = cadre.maxY - voulue
        cadre.size.height = voulue
        if cadre.minY < ecran.minY { cadre.origin.y = ecran.minY }
        f.setFrame(cadre, display: true, animate: f.isVisible)
    }

    func windowWillClose(_ n: Notification) {
        if !moteur.affichage.dock { NSApp.setActivationPolicy(.accessory) }
    }
}
