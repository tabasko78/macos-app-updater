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
    /// « arm » ou « intel », les mots des casks Homebrew.
    static var processeur: String { puceApple ? "arm" : "intel" }

    /// Processeurs pour lesquels le programme principal d'une app est fait (« arm », « intel »), lus dans
    /// l'en-tête Mach-O : nil si illisible. Rien n'est lancé, quelques octets suffisent.
    static func processeurs(app: String) -> Set<String>? {
        let info = NSDictionary(contentsOfFile: app + "/Contents/Info.plist") as? [String: Any]
        guard let exe = info?["CFBundleExecutable"] as? String,
              let h = FileHandle(forReadingAtPath: app + "/Contents/MacOS/" + exe) else { return nil }
        defer { try? h.close() }
        guard let d = try? h.read(upToCount: 4096), d.count >= 8 else { return nil }
        let o = [UInt8](d)
        func be(_ i: Int) -> UInt32 { i + 4 <= o.count ? UInt32(o[i]) << 24 | UInt32(o[i+1]) << 16 | UInt32(o[i+2]) << 8 | UInt32(o[i+3]) : 0 }
        func le(_ i: Int) -> UInt32 { i + 4 <= o.count ? UInt32(o[i+3]) << 24 | UInt32(o[i+2]) << 16 | UInt32(o[i+1]) << 8 | UInt32(o[i]) : 0 }
        func nom(_ t: UInt32) -> String? { t == 0x0100_000C ? "arm" : t == 0x0100_0007 ? "intel" : nil }
        switch be(0) {
        case 0xCAFE_BABE, 0xCAFE_BABF:   // app universelle : une entrée par processeur (20 octets, 32 en 64 bits)
            let n = Int(be(4)), pas = be(0) == 0xCAFE_BABF ? 32 : 20
            guard n > 0, n < 16 else { return nil }
            let r = Set((0..<n).compactMap { nom(be(8 + $0 * pas)) })
            return r.isEmpty ? nil : r
        case 0xCFFA_EDFE:                // un seul processeur, en-tête petit-boutiste
            return nom(le(4)).map { [$0] }
        default:
            return nil
        }
    }

    /// L'app peut-elle s'ouvrir ici ? Une puce Apple ouvre aussi les apps Intel (Rosetta), un Mac Intel jamais
    /// une app faite pour puce Apple seule. nil : impossible à savoir.
    static func tourne(app: String) -> Bool? {
        guard let p = processeurs(app: app) else { return nil }
        return puceApple || p.contains("intel")
    }

    /// Pourquoi une app ne s'ouvre pas ici.
    static var raisonProcesseur: String {
        puceApple ? L.t("faite pour les Mac Intel", "made for Intel Macs") : L.t("faite pour les puces Apple, ce Mac est Intel", "made for Apple silicon, this Mac is Intel")
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
    var dateAjout: Date? = nil             // posée dans son dossier (installée ou remplacée) ce jour-là
    var tourneIci = true                   // false : la version installée ne peut pas s'ouvrir sur ce Mac

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
                     derniereUtilisation: derniereUtilisation, dateAjout: dateAjout, tourneIci: tourneIci)
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
