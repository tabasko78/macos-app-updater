import Foundation

enum Source: String, Sendable {
    case homebrew = "Homebrew"
    case sparkle = "Sparkle"
    case appStore = "App Store"
    case github = "GitHub"
    case editeur = "Éditeur"
    case composant = "Composant"
    case integree = "Intégrée"
    case abandonnee = "Abandonnée"
    case perso = "Perso"
    case aucune = "Aucune source"

    var libelle: String {
        switch self {
        case .homebrew: "Homebrew"
        case .sparkle: "Sparkle"
        case .appStore: "App Store"
        case .github: "GitHub"
        case .editeur: L.t("Éditeur", "Developer")
        case .composant: L.t("Composant", "Component")
        case .integree: L.t("Intégrée", "Self-updating")
        case .abandonnee: L.t("Abandonnée", "Discontinued")
        case .perso: L.t("Perso", "Personal")
        case .aucune: L.t("Aucune source", "No source")
        }
    }
}

/// Ce que fait le bouton d'une ligne quand une mise à jour existe.
enum Action: Equatable, Sendable {
    case brew(token: String, terminal: Bool)   // terminal : paquet .pkg, il faut le mot de passe administrateur
    case installer(URL, sha256: String?)       // fichier .zip ou .dmg de la nouvelle version, installé sans Homebrew
    case appStore(URL)
    case telecharger(URL)
    case ouvrirApp
    case page(URL)
    case aucune
}

struct CaskInfo: Codable, Sendable {
    let token: String
    let url: String?          // adresse du téléchargement, sert à mesurer sa progression
    let version: String?      // nil quand le cask publie « latest »
    let apps: [String]        // noms des .app que le cask installe, vide pour un .pkg
    let terminal: Bool
    let autoUpdates: Bool
    var retire = false        // cask retiré de Homebrew : sa dernière version reste connue, il ne s'installe plus
    var minMacOS: String? = nil   // version de macOS demandée par la dernière version (« 14 »)
    var archs: [String]? = nil    // processeurs acceptés (« arm », « intel ») ; nil : tous
}

/// Le Mac sur lequel tourne l'app : version de macOS et processeur, pour écarter les versions incompatibles.
enum CeMac {
    static var macOS: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }
    static var puceApple: Bool {
        #if arch(arm64)
        true
        #else
        false
        #endif
    }
    /// Clé des variantes du catalogue Homebrew pour ce Mac : « ventura » (Intel), « arm64_sequoia »…
    static var varianteHomebrew: String {
        let noms = [11: "big_sur", 12: "monterey", 13: "ventura", 14: "sonoma", 15: "sequoia", 26: "tahoe", 27: "golden_gate"]
        let nom = noms[ProcessInfo.processInfo.operatingSystemVersion.majorVersion] ?? "golden_gate"
        return (puceApple ? "arm64_" : "") + nom
    }
}

struct AppInstallee: Identifiable, Sendable {
    var id: String { chemin }
    let chemin: String
    let nom: String
    let bundleId: String
    let version: String       // CFBundleShortVersionString
    let build: String         // CFBundleVersion
    let feedSparkle: URL?
    let mas: Bool
    var derniereUtilisation: Date? = nil   // relevée par Spotlight

    var source: Source = .aucune
    var disponible: String? = nil
    var aJour: Bool? = nil    // nil : impossible à savoir
    var action: Action = .aucune
    var cask: CaskInfo? = nil
    var remarque: String? = nil
    var majeure = false                    // saut de version majeure : jamais mise à jour automatiquement
    var datePublication: Date? = nil       // quand la source la donne (App Store, GitHub, Sparkle)
    var notes: String? = nil               // notes de version, quand la source les donne
    var notesLien: URL? = nil              // ou l'adresse où les lire (Sparkle)
    var incompatible: String? = nil        // la nouvelle version ne peut pas tourner sur ce Mac : pourquoi

    var versionAffichee: String { version.isEmpty ? build : version }

    /// Les seuls champs lus sur le disque : le point de départ pour réévaluer une app.
    var brute: AppInstallee {
        AppInstallee(chemin: chemin, nom: nom, bundleId: bundleId, version: version, build: build, feedSparkle: feedSparkle, mas: mas,
                     derniereUtilisation: derniereUtilisation)
    }
}

enum Dossiers {
    /// Identifiant de l'app en cours (la copie perso et la version publique n'ont pas le même).
    static let id = Bundle.main.bundleIdentifier ?? "io.github.tabasko78.macos-app-updater"

    static var caches: URL { dossier(.cachesDirectory) }
    static var support: URL { dossier(.applicationSupportDirectory) }

    private static func dossier(_ d: FileManager.SearchPathDirectory) -> URL {
        let u = FileManager.default.urls(for: d, in: .userDomainMask)[0].appendingPathComponent(id)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
}

extension Array {
    func paquets(_ n: Int) -> [[Element]] {
        stride(from: 0, to: count, by: n).map { Array(self[$0..<Swift.min($0 + n, count)]) }
    }
}
