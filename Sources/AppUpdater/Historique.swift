import Foundation

/// Une ligne du journal : une version qui a changé, une app installée, désinstallée ou disparue.
struct EntreeJournal: Codable, Identifiable {
    var id = UUID()
    let date: Date
    let nom: String
    let bundleId: String
    let avant: String?
    let apres: String?
    let quoi: String       // « Mise à jour », « Installée », « Désinstallée », « Disparue »
    let par: String        // « Homebrew », « hors de l'app », « Mises à jour »…
}

/// Journal et dernières versions vues, dans ~/Library/Application Support/<identifiant de l'app>/
enum Historique {
    private static var fichierJournal: URL { Dossiers.support.appendingPathComponent("journal.json") }
    private static var fichierVersions: URL { Dossiers.support.appendingPathComponent("versions-vues.json") }

    static func journal() -> [EntreeJournal] {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return (try? Data(contentsOf: fichierJournal)).flatMap { try? d.decode([EntreeJournal].self, from: $0) } ?? []
    }

    static func enregistrer(_ j: [EntreeJournal]) {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = .prettyPrinted
        try? e.encode(Array(j.prefix(3000))).write(to: fichierJournal, options: .atomic)
    }

    /// chemin de l'app → « nom|version »
    static func versionsVues() -> [String: String] {
        (try? Data(contentsOf: fichierVersions)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
    }

    static func enregistrer(versions: [String: String]) {
        try? JSONEncoder().encode(versions).write(to: fichierVersions, options: .atomic)
    }
}

/// Taille sur le disque de chaque app, gardée tant que sa version ne change pas (la mesure parcourt tout le paquet).
enum Tailles {
    struct Entree: Codable { let version: String; let taille: Int64 }
    private static var fichier: URL { Dossiers.caches.appendingPathComponent("tailles.json") }

    static func lire() -> [String: Entree] {
        (try? Data(contentsOf: fichier)).flatMap { try? JSONDecoder().decode([String: Entree].self, from: $0) } ?? [:]
    }

    static func ecrire(_ t: [String: Entree]) {
        try? JSONEncoder().encode(t).write(to: fichier, options: .atomic)
    }
}
