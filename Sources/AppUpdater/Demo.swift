import Foundation

/// --demo : la fenêtre se remplit d'une liste fictive (versions et résumés inventés) pour les captures d'écran du
/// README. Rien n'est lu ni vérifié, et aucun bouton n'agit : on ne peut rien mettre à jour ni désinstaller.
/// Les icônes sont celles des apps présentes dans /Applications ; absente, une app a l'icône générique.
enum Demo {
    static let actif = CommandLine.arguments.contains("--demo")

    private static func jours(_ n: Double) -> Date { Date().addingTimeInterval(-n * 86_400) }

    private static func app(_ nom: String, _ id: String, _ version: String, _ source: Source, mas: Bool = false,
                            nouvelle: String? = nil, action: Action = .aucune, cask: CaskInfo? = nil,
                            utilisee: Double?, ajoutee: Double) -> AppInstallee {
        var a = AppInstallee(chemin: "/Applications/\(nom).app", nom: nom, bundleId: id, version: version, build: version,
                             feedSparkle: nil, mas: mas, derniereUtilisation: utilisee.map(jours), dateAjout: jours(ajoutee))
        a.source = source
        a.disponible = nouvelle ?? version
        a.aJour = nouvelle == nil
        a.action = action
        a.cask = cask
        return a
    }

    private static func cask(_ token: String, _ url: String, apps: [String] = [], pkg: Bool = false) -> CaskInfo {
        CaskInfo(token: token, url: url, version: nil, apps: apps, terminal: pkg, autoUpdates: true)
    }

    private static let page = URL(string: "https://example.com")!

    static let apps: [AppInstallee] = [
        // Mises à jour proposées
        app("Firefox", "org.mozilla.firefox", "144.0.2", .homebrew, nouvelle: "145.0", action: .brew(token: "firefox", terminal: false), utilisee: 0.02, ajoutee: 12),
        app("VLC", "org.videolan.vlc", "3.0.21", .sparkle, nouvelle: "3.0.22", action: .installer(page, sha256: nil), utilisee: 3, ajoutee: 140),
        app("Visual Studio Code", "com.microsoft.VSCode", "1.105.1", .homebrew, nouvelle: "1.106.0", action: .brew(token: "visual-studio-code", terminal: false), utilisee: 0.2, ajoutee: 26),
        app("Keynote", "com.apple.iWork.Keynote", "14.4", .appStore, mas: true, nouvelle: "14.5", action: .appStore(page), utilisee: 9, ajoutee: 60),
        app("LosslessCut", "no.mifi.losslesscut", "3.64.0", .github, nouvelle: "3.65.0", action: .page(page), utilisee: 21, ajoutee: 75),
        // À jour
        app("AppCleaner", "net.freemacsoft.AppCleaner", "3.6.8", .homebrew, utilisee: 5, ajoutee: 200),
        app("ImageOptim", "net.pornel.ImageOptim", "1.9.3", .sparkle, utilisee: 14, ajoutee: 90),
        app("Keka", "com.aone.keka", "1.6.2", .homebrew, utilisee: 2, ajoutee: 33),
        app("Google Chrome", "com.google.Chrome", "142.0.7444.60", .integree, utilisee: 1, ajoutee: 4),
        app("Spotify", "com.spotify.client", "1.2.74", .integree, utilisee: 0.1, ajoutee: 6),
        app("Shotcut", "org.shotcut.Shotcut", "25.10.31", .github, utilisee: 40, ajoutee: 8),
        app("DeepL", "com.linguee.DeepLCopyTranslator", "25.11.1", .editeur, utilisee: 0.5, ajoutee: 3),
        // App Store : avec ou sans version de l'éditeur
        app("Numbers", "com.apple.iWork.Numbers", "14.4", .appStore, mas: true, utilisee: 30, ajoutee: 60),
        app("Pages", "com.apple.iWork.Pages", "14.4", .appStore, mas: true, utilisee: 12, ajoutee: 60),
        app("Microsoft Word", "com.microsoft.Word", "16.103", .appStore, mas: true,
            cask: cask("microsoft-word", "https://example.com/Microsoft_Word_Installer.pkg", pkg: true), utilisee: 4, ajoutee: 15),
        app("Microsoft Excel", "com.microsoft.Excel", "16.103", .appStore, mas: true,
            cask: cask("microsoft-excel", "https://example.com/Microsoft_Excel_Installer.pkg", pkg: true), utilisee: 7, ajoutee: 15),
        app("Tailscale", "io.tailscale.ipn.macsys", "1.90.6", .appStore, mas: true,
            cask: cask("tailscale-app", "https://example.com/Tailscale.zip", apps: ["Tailscale.app"]), utilisee: 0.3, ajoutee: 20),
        app("The Unarchiver", "com.macpaw.site.theunarchiver", "4.3.9", .appStore, mas: true,
            cask: cask("the-unarchiver", "https://example.com/TheUnarchiver.zip", apps: ["The Unarchiver.app"]), utilisee: 18, ajoutee: 110),
        app("TestFlight", "com.apple.TestFlight", "3.8.1", .appStore, mas: true, utilisee: nil, ajoutee: 300),
    ].sorted { $0.nom.localizedCaseInsensitiveCompare($1.nom) == .orderedAscending }

    /// Taille sur le disque, en Mo.
    static let tailles: [String: Int64] = Dictionary(uniqueKeysWithValues: [
        ("Firefox", 412), ("VLC", 186), ("Visual Studio Code", 640), ("Keynote", 732), ("LosslessCut", 389), ("AppCleaner", 9),
        ("ImageOptim", 28), ("Keka", 61), ("Google Chrome", 1_240), ("Spotify", 512), ("Shotcut", 395), ("DeepL", 233),
        ("Numbers", 598), ("Pages", 645), ("Microsoft Word", 2_310), ("Microsoft Excel", 2_150), ("Tailscale", 79),
        ("The Unarchiver", 34), ("TestFlight", 41),
    ].map { ("/Applications/\($0.0).app", Int64($0.1) * 1_000_000) })

    /// Résumés en deux phrases, comme ceux de Gemini (« web| » : trouvé par une recherche web).
    static let resumes: [String: String] = [
        "org.mozilla.firefox@145.0": L.t("Ajoute le regroupement automatique des onglets. Corrige plusieurs failles de sécurité.", "Adds automatic tab grouping. Fixes several security issues."),
        "org.videolan.vlc@3.0.22": L.t("Corrige la lecture de certains fichiers MKV et améliore la prise en charge des sous-titres.", "Fixes playback of some MKV files and improves subtitle support."),
        "com.microsoft.VSCode@1.106.0": L.t("Nouvelle vue des modifications en attente et terminal plus rapide. Corrige des plantages au démarrage.", "New pending changes view and a faster terminal. Fixes startup crashes."),
        "com.apple.iWork.Keynote@14.5": "web|" + L.t("Corrections de bugs et améliorations de stabilité.", "Bug fixes and stability improvements."),
    ]
}
