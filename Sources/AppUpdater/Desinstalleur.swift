import Foundation

/// Un fichier laissé par une app ailleurs que dans son paquet .app.
struct Residu: Identifiable, Sendable {
    var id: String { chemin }
    let chemin: String
    let taille: Int64?        // nil : pas mesuré (dossier protégé d'une autre app)
    var coche: Bool
    let raison: String
    var douteux = false        // nom seulement approchant : proposé décoché
    var protege = false        // dossier protégé par macOS : demande l'Accès complet au disque
}

/// Désinstallation à la manière d'AppCleaner : l'app, puis tout ce qui porte son identifiant dans les Library.
/// Rien n'est effacé : tout part à la Corbeille, d'où l'on peut le remettre en place.
enum Desinstalleur {
    /// macOS protège les données des autres apps (Containers, Group Containers, Application Scripts) :
    /// sans l'Accès complet au disque, ni l'app ni le Finder ne peuvent les déplacer.
    static func protege(_ chemin: String) -> Bool {
        ["/Library/Containers/", "/Library/Group Containers/", "/Library/Application Scripts/"].contains { chemin.contains($0) }
    }

    /// Vrai si l'app a l'Accès complet au disque : seule une app qui l'a peut ouvrir la base TCC.
    static var accesComplet: Bool {
        guard let h = FileHandle(forReadingAtPath: "/Library/Application Support/com.apple.TCC/TCC.db") else { return false }
        try? h.close()
        return true
    }

    static func chercher(_ a: AppInstallee) -> [Residu] {
        let fm = FileManager.default
        let h = NSHomeDirectory()
        let id = a.bundleId.lowercased()
        let info = NSDictionary(contentsOfFile: a.chemin + "/Contents/Info.plist") as? [String: Any]
        let exe = (info?["CFBundleExecutable"] as? String ?? "").lowercased()
        let nom = a.nom.lowercased()
        // Un nom exact est sûr ; une variante (sans espaces, nom de l'exécutable) est proposée décochée.
        let variantes = Set([nom.replacingOccurrences(of: " ", with: ""), exe].filter { $0.count >= 4 && $0 != nom })

        let complet = accesComplet
        var r = [Residu(chemin: a.chemin, taille: taille(a.chemin), coche: true, raison: L.t("l'application", "the app"))]
        // (dossier, mesurer la taille) : les conteneurs d'une autre app ne se lisent pas sans demande d'autorisation macOS
        let lieux: [(String, Bool)] = [
            (h + "/Library/Application Support", true), (h + "/Library/Caches", true),
            (h + "/Library/Preferences", true), (h + "/Library/Preferences/ByHost", true),
            (h + "/Library/Containers", false), (h + "/Library/Group Containers", false),
            (h + "/Library/Application Scripts", false), (h + "/Library/Saved Application State", true),
            (h + "/Library/Logs", true), (h + "/Library/HTTPStorages", true), (h + "/Library/WebKit", true),
            (h + "/Library/Cookies", true), (h + "/Library/LaunchAgents", true),
            ("/Library/Application Support", true), ("/Library/Caches", true), ("/Library/Preferences", true),
            ("/Library/LaunchAgents", true), ("/Library/LaunchDaemons", true),
            ("/Library/PrivilegedHelperTools", true), ("/Library/Logs", true),
        ]
        for (d, mesurer) in lieux {
            guard let items = try? fm.contentsOfDirectory(atPath: d) else { continue }
            for i in items where !i.hasPrefix(".") {
                let n = i.lowercased()
                let base = (n as NSString).deletingPathExtension
                var coche = false, raison = "", douteux = false
                if !id.isEmpty && (base == id || n.hasPrefix(id + ".") || n.hasPrefix(id + "_")
                    || (d.hasSuffix("Group Containers") && n.hasSuffix("." + id))) {
                    coche = true; raison = L.t("identifiant", "bundle ID")
                } else if n == nom || base == nom {
                    coche = true; raison = L.t("nom de l'app", "app name")
                } else if variantes.contains(n) || variantes.contains(base) {
                    raison = L.t("nom approchant", "similar name"); douteux = true
                } else {
                    continue
                }
                let p = d + "/" + i
                if protege(p) && !complet {
                    r.append(Residu(chemin: p, taille: nil, coche: false, raison: L.t("protégé par macOS", "protected by macOS"), protege: true))
                } else {
                    r.append(Residu(chemin: p, taille: mesurer ? taille(p) : nil, coche: coche, raison: raison, douteux: douteux))
                }
            }
        }
        return r
    }

    static func taille(_ chemin: String) -> Int64 {
        let u = URL(fileURLWithPath: chemin)
        let cles: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isDirectoryKey]
        guard (try? u.resourceValues(forKeys: cles))?.isDirectory == true else {
            return Int64((try? u.resourceValues(forKeys: cles))?.totalFileAllocatedSize ?? 0)
        }
        var total: Int64 = 0
        let e = FileManager.default.enumerator(at: u, includingPropertiesForKeys: Array(cles), options: [], errorHandler: { _, _ in true })
        while let f = e?.nextObject() as? URL {
            total += Int64((try? f.resourceValues(forKeys: cles))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    /// Renvoie les chemins qui n'ont pas pu partir.
    static func mettreALaCorbeille(_ chemins: [String]) async -> [String] {
        let fm = FileManager.default
        var echecs: [String] = []
        for c in chemins where fm.fileExists(atPath: c) {
            do { try fm.trashItem(at: URL(fileURLWithPath: c), resultingItemURL: nil) } catch { echecs.append(c) }
        }
        // Fichiers appartenant au système (apps de l'App Store, dossiers de /Library) : déplacés dans la
        // Corbeille avec le mot de passe administrateur, demandé par la fenêtre standard de macOS.
        let systeme = echecs.filter { !protege($0) }
        if !systeme.isEmpty {
            let corbeille = NSHomeDirectory() + "/.Trash/"
            let horodatage = Int(Date().timeIntervalSince1970)
            let cmd = systeme.map { c -> String in
                var nom = (c as NSString).lastPathComponent
                if fm.fileExists(atPath: corbeille + nom) { nom = "\(horodatage) \(nom)" }
                return "/bin/mv -f \(guillemets(c)) \(guillemets(corbeille + nom))"
            }.joined(separator: " && ")
            let script = "do shell script \"\(cmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
            _ = await Shell.lancer("/usr/bin/osascript", ["-e", script], delai: 180)
        }
        return echecs.filter { fm.fileExists(atPath: $0) }
    }

    private static func guillemets(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// « 547,1 Mo » en français, « 547.1 MB » en anglais.
    static func lisible(_ octets: Int64) -> String {
        let x = Double(octets)
        let (v, u, chiffres): (Double, String, Int) =
            x >= 1e9 ? (x / 1e9, L.t("Go", "GB"), 2) : x >= 1e6 ? (x / 1e6, L.t("Mo", "MB"), 1) : x >= 1e3 ? (x / 1e3, L.t("Ko", "KB"), 0) : (x, L.t("octets", "bytes"), 0)
        return v.formatted(.number.precision(.fractionLength(chiffres)).locale(L.locale)) + " " + u
    }
}
