import Foundation

struct ErreurSource: Error, LocalizedError {
    let errorDescription: String?
    init(_ m: String) { errorDescription = m }
}

// MARK: - Homebrew : le catalogue public des casks, environ 7 000 applications

enum Homebrew {
    /// /opt/homebrew sur puce Apple, /usr/local sur Intel.
    static let chemin = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/opt/homebrew/bin/brew"
    static var present: Bool { FileManager.default.isExecutableFile(atPath: chemin) }

    struct Index: Codable, Sendable {
        var casks: [CaskInfo] = []
        var parNom: [String: Int] = [:]     // nom du .app, en minuscules
        var parQuit: [String: Int] = [:]    // bundle id que le cask ferme avant désinstallation
        var parPref: [String: Int] = [:]    // bundle id tiré de ~/Library/Preferences/<id>.plist

        func trouver(_ a: AppInstallee) -> CaskInfo? {
            let nom = (a.chemin as NSString).lastPathComponent.lowercased()
            let id = a.bundleId.lowercased()
            return (parNom[nom] ?? parQuit[id] ?? parPref[id]).map { casks[$0] }
        }
    }

    static var fichierIndex: URL { Dossiers.caches.appendingPathComponent("index-brew-v2.json") }   // v2 : exigences macOS et processeur

    /// L'index réduit (quelques Mo) est fabriqué par un second processus : analyser le catalogue
    /// complet (19 Mo de JSON) dans l'app gonflerait sa mémoire pour toute la durée de sa vie.
    static func charger() async throws -> Index {
        let f = fichierIndex
        let date = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if let date, -date.timeIntervalSinceNow < 3 * 3600, let i = lire(f) { return i }
        if let exe = Bundle.main.executablePath {
            let r = await Shell.lancer(exe, ["--index-brew", f.path])
            if r.code == 0, let i = lire(f) { return i }
        }
        if let i = lire(f) { return i }   // hors ligne : la dernière copie vaut mieux que rien
        throw ErreurSource(L.t("catalogue Homebrew injoignable", "Homebrew catalog unreachable"))
    }

    private static func lire(_ f: URL) -> Index? {
        (try? Data(contentsOf: f)).flatMap { try? JSONDecoder().decode(Index.self, from: $0) }
    }

    /// Appelé dans le second processus : télécharge le catalogue, écrit l'index réduit.
    static func construireIndex(vers chemin: String) async -> Int32 {
        do {
            var req = URLRequest(url: URL(string: "https://formulae.brew.sh/api/cask.json")!, timeoutInterval: 90)
            req.setValue("AppUpdater/1.0", forHTTPHeaderField: "User-Agent")
            let (d, rep) = try await URLSession.shared.data(for: req)
            guard (rep as? HTTPURLResponse)?.statusCode == 200 else { return 1 }
            try JSONEncoder().encode(try analyser(d)).write(to: URL(fileURLWithPath: chemin), options: .atomic)
            return 0
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            return 1
        }
    }

    static func analyser(_ data: Data) throws -> Index {
        guard let casks = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw ErreurSource(L.t("catalogue Homebrew illisible", "Homebrew catalog unreadable"))
        }
        var idx = Index()
        let variante = CeMac.varianteHomebrew
        for brut in casks {
            // Les champs propres à ce Mac (version, adresse, exigences) remplacent ceux par défaut, faits pour
            // la puce Apple sur le dernier macOS : un iMac Intel en Ventura a parfois une autre version.
            var c = brut
            if let v = (brut["variations"] as? [String: Any])?[variante] as? [String: Any] {
                for (k, val) in v { c[k] = val }
            }
            guard let token = c["token"] as? String else { continue }
            let retire = c["disabled"] as? Bool == true
            var version = c["version"] as? String
            if version == "latest" { version = nil }
            if let v = version, let i = v.firstIndex(of: ",") { version = String(v[..<i]) }

            var noms: [String] = [], quits: [String] = [], prefs: [String] = []
            var terminal = false
            for art in c["artifacts"] as? [[String: Any]] ?? [] {
                if let apps = art["app"] as? [Any] {
                    for e in apps {
                        if let s = e as? String {
                            noms.append(base(s))
                        } else if let d = e as? [String: Any], let t = d["target"] as? String, !noms.isEmpty {
                            noms[noms.count - 1] = base(t)
                        }
                    }
                    if let t = art["target"] as? String { noms.append(base(t)) }
                }
                if art["pkg"] != nil || art["installer"] != nil { terminal = true }
                for d in art["uninstall"] as? [[String: Any]] ?? [] { quits += chaines(d["quit"]) }
                for d in art["zap"] as? [[String: Any]] ?? [] {
                    prefs += (chaines(d["trash"]) + chaines(d["delete"])).compactMap(idPreference)
                }
            }
            let n = idx.casks.count
            let dep = c["depends_on"] as? [String: Any]
            let macos = dep?["macos"] as? [String: Any]
            let minMacOS = ((macos?[">="] ?? macos?["=="]) as? [String])?.min { Versions.comparer($0, $1) == .orderedAscending }
            let archs = (dep?["arch"] as? [[String: Any]])?.compactMap { $0["type"] as? String }
            idx.casks.append(CaskInfo(token: token, url: c["url"] as? String, version: version, apps: noms,
                                      terminal: terminal, autoUpdates: c["auto_updates"] as? Bool ?? false, retire: retire,
                                      minMacOS: minMacOS, archs: archs))
            for x in noms { ranger(&idx.parNom, x.lowercased(), n, idx.casks) }
            for x in quits { ranger(&idx.parQuit, x.lowercased(), n, idx.casks) }
            for x in prefs { ranger(&idx.parPref, x.lowercased(), n, idx.casks) }
        }
        return idx
    }

    /// Premier arrivé, sauf qu'une variante (firefox@esr, @beta…) cède la place au cask principal.
    private static func ranger(_ d: inout [String: Int], _ cle: String, _ n: Int, _ casks: [CaskInfo]) {
        // Premier arrivé, sauf qu'une variante (@beta…) ou un cask retiré cède la place.
        if let e = d[cle], !(casks[e].token.contains("@") && !casks[n].token.contains("@")),
           !(casks[e].retire && !casks[n].retire) { return }
        d[cle] = n
    }

    private static func base(_ s: String) -> String { (s as NSString).lastPathComponent }

    private static func chaines(_ v: Any?) -> [String] {
        if let s = v as? String { return [s] }
        return v as? [String] ?? []
    }

    private static func idPreference(_ p: String) -> String? {
        guard p.contains("/Library/Preferences/"), !p.contains("ByHost"), p.hasSuffix(".plist"), !p.contains("*") else { return nil }
        return ((p as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    /// Casks installés par Homebrew lui-même (ceux-là se mettent à jour par `upgrade`) → version installée.
    static func installes() async -> [String: String] {
        guard present else { return [:] }
        let r = await Shell.lancer(chemin, ["list", "--cask", "--versions"], env: ["HOMEBREW_NO_AUTO_UPDATE": "1"])
        guard r.code == 0 else { return [:] }
        var v: [String: String] = [:]
        for l in r.sortie.split(separator: "\n") {
            let m = l.split(separator: " ").map(String.init)
            if m.count >= 2 { v[m[0]] = m.last! } else if m.count == 1 { v[m[0]] = "" }
        }
        return v
    }
}

// MARK: - Sparkle : le flux de mise à jour inscrit dans l'application

enum Sparkle {
    struct Element: Sendable {
        var court: String?
        var build: String?
        var url: URL?
        var canal: String?
        var minOS: String?
        var date: Date?
        var notes: String?
        var notesLien: URL?
    }

    static func verifier(_ feed: URL) async throws -> Element? {
        var req = URLRequest(url: feed, timeoutInterval: 20)
        req.setValue("AppUpdater/1.0 Sparkle/2", forHTTPHeaderField: "User-Agent")
        let (data, rep) = try await URLSession.shared.data(for: req)
        if let h = rep as? HTTPURLResponse, h.statusCode >= 400 { throw ErreurSource(L.t("flux Sparkle en erreur \(h.statusCode)", "Sparkle feed error \(h.statusCode)")) }
        let a = AnalyseurAppcast()
        let x = XMLParser(data: data)
        x.delegate = a
        guard x.parse() else { throw ErreurSource(L.t("flux Sparkle illisible", "Sparkle feed unreadable")) }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let osTxt = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        let valides = a.elements.filter { e in
            e.canal == nil && (e.court != nil || e.build != nil)
                && (e.minOS.map { Versions.comparer($0, osTxt) != .orderedDescending } ?? true)
        }
        return valides.max { Versions.comparer($0.build ?? $0.court!, $1.build ?? $1.court!) == .orderedAscending }
    }

    static func verifierTous(_ feeds: [(String, URL)]) async -> [String: Result<Element?, Error>] {
        await withTaskGroup(of: (String, Result<Element?, Error>).self) { g in
            for (chemin, url) in feeds {
                g.addTask {
                    do { return (chemin, .success(try await verifier(url))) } catch { return (chemin, .failure(error)) }
                }
            }
            var r: [String: Result<Element?, Error>] = [:]
            for await (c, e) in g { r[c] = e }
            return r
        }
    }
}

final class AnalyseurAppcast: NSObject, XMLParserDelegate {
    var elements: [Sparkle.Element] = []
    private var courant: Sparkle.Element?
    private var texte = ""
    private var dansDeltas = false

    func parser(_ p: XMLParser, didStartElement n: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
        texte = ""
        switch n {
        case "item": courant = Sparkle.Element()
        case "sparkle:deltas": dansDeltas = true
        case "enclosure" where courant != nil && !dansDeltas:
            if let u = a["url"] { courant?.url = URL(string: u) }
            if let v = a["sparkle:version"] { courant?.build = v }
            if let v = a["sparkle:shortVersionString"] { courant?.court = v }
        default: break
        }
    }

    func parser(_ p: XMLParser, foundCharacters s: String) { texte += s }
    func parser(_ p: XMLParser, foundCDATA d: Data) { texte += String(decoding: d, as: UTF8.self) }

    private static let formatDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return f
    }()

    func parser(_ p: XMLParser, didEndElement n: String, namespaceURI: String?, qualifiedName: String?) {
        let t = texte.trimmingCharacters(in: .whitespacesAndNewlines)
        switch n {
        case "item":
            if let c = courant { elements.append(c) }
            courant = nil
        case "sparkle:deltas": dansDeltas = false
        case "sparkle:version" where !t.isEmpty: courant?.build = t
        case "sparkle:shortVersionString" where !t.isEmpty: courant?.court = t
        case "sparkle:channel" where !t.isEmpty: courant?.canal = t
        case "sparkle:minimumSystemVersion" where !t.isEmpty: courant?.minOS = t
        case "pubDate" where !t.isEmpty: courant?.date = Self.formatDate.date(from: t)
        case "description" where !t.isEmpty && courant != nil: courant?.notes = t
        case "sparkle:releaseNotesLink" where !t.isEmpty: courant?.notesLien = URL(string: t)
        default: break
        }
        texte = ""
    }
}

// MARK: - Mac App Store : l'API publique de recherche d'Apple, sans compte

enum AppStore {
    struct Fiche: Sendable {
        let version: String
        let url: URL?
        var date: Date? = nil
        var notes: String? = nil
        var minOS: String? = nil
        var appIPhone = false     // app iPhone ou iPad : ne tourne que sur puce Apple
    }

    static func verifier(_ ids: [String]) async throws -> [String: Fiche] {
        var res: [String: Fiche] = [:]
        for pays in ["fr", "us"] {
            let manquants = ids.filter { res[$0.lowercased()] == nil }
            for lot in manquants.paquets(40) {
                var c = URLComponents(string: "https://itunes.apple.com/lookup")!
                c.queryItems = [.init(name: "bundleId", value: lot.joined(separator: ",")), .init(name: "country", value: pays)]
                let (data, _) = try await URLSession.shared.data(from: c.url!)
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                for r in json?["results"] as? [[String: Any]] ?? [] {
                    guard let b = r["bundleId"] as? String, let v = r["version"] as? String else { continue }
                    res[b.lowercased()] = Fiche(version: v, url: (r["trackViewUrl"] as? String).flatMap(URL.init(string:)),
                                                date: (r["currentVersionReleaseDate"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) },
                                                notes: r["releaseNotes"] as? String,
                                                minOS: r["minimumOsVersion"] as? String,
                                                appIPhone: (r["kind"] as? String) == "software")
                }
            }
        }
        return res
    }
}

// MARK: - Règles : pour les apps sans flux public, une adresse que l'éditeur tient à jour

enum Regles {
    /// `depot` : un dépôt GitHub (« proprietaire/depot ») ; ou `json` : une adresse qui renvoie du JSON,
    /// `chemin` y désigne la version (« mac.version »), `telechargement` le lien du fichier ; `page` : ce qu'ouvre le bouton.
    struct Regle: Codable, Sendable {
        let bundleId: String
        var depot: String? = nil
        var json: String? = nil
        var chemin: String? = nil
        var telechargement: String? = nil
        var page: String? = nil
    }

    struct Publication: Sendable {
        let version: String
        let url: URL?              // page à ouvrir
        let source: Source
        var fichier: URL? = nil    // .zip ou .dmg de la nouvelle version, s'il est connu
        var sha256: String? = nil
        var date: Date? = nil
        var notes: String? = nil
    }

    /// Un fichier qu'Installeur sait ouvrir.
    static func installable(_ u: URL?) -> URL? {
        guard let u, ["zip", "dmg"].contains(u.pathExtension.lowercased()) else { return nil }
        return u
    }

    /// Trouvées le 29/10/2026 en fouillant les apps elles-mêmes : c'est l'adresse que leur propre
    /// système de mise à jour interroge.
    static let integrees: [Regle] = [
        Regle(bundleId: "com.mobeesoft.vidjuice", json: "https://file.vidjuice.com/update.json",
              chemin: "mac.version", telechargement: "mac.arm64url", page: "https://www.vidjuice.com/"),
        Regle(bundleId: "com.pcloud.pcloud.macos", json: "https://api.pcloud.com/getlastversion?os=MAC",
              chemin: "versionstr", page: "https://www.pcloud.com/download-free-online-cloud-file-storage.html"),
    ]

    static var fichier: URL { Dossiers.support.appendingPathComponent("regles.json") }

    /// bundle id → règle ; celles du fichier passent avant les intégrées.
    static func toutes() -> [String: Regle] {
        let f = fichier
        if !FileManager.default.fileExists(atPath: f.path) { try? Data("[]\n".utf8).write(to: f) }
        let perso = (try? Data(contentsOf: f)).flatMap { try? JSONDecoder().decode([Regle].self, from: $0) } ?? []
        var r: [String: Regle] = [:]
        for x in integrees + perso { r[x.bundleId] = x }
        return r
    }

    /// Les apps faites avec Electron décrivent souvent leur source dans Contents/Resources/app-update.yml.
    static func depuisElectron(_ a: AppInstallee) -> Regle? {
        guard let t = try? String(contentsOfFile: a.chemin + "/Contents/Resources/app-update.yml", encoding: .utf8) else { return nil }
        var v: [String: String] = [:]
        for l in t.split(separator: "\n") {
            let p = l.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if p.count == 2 { v[p[0]] = p[1].trimmingCharacters(in: CharacterSet(charactersIn: "'\"")) }
        }
        if v["provider"] == "github", let o = v["owner"], let r = v["repo"] { return Regle(bundleId: a.bundleId, depot: "\(o)/\(r)") }
        if v["provider"] == "generic", let u = v["url"] {
            return Regle(bundleId: a.bundleId, json: (u.hasSuffix("/") ? u : u + "/") + "latest-mac.yml", chemin: "version")
        }
        return nil
    }

    static func verifier(_ r: Regle) async throws -> Publication {
        if let d = r.depot { return try await github(d) }
        guard let j = r.json, let u = URL(string: j) else { throw ErreurSource(L.t("règle incomplète", "incomplete rule")) }
        var req = URLRequest(url: u, timeoutInterval: 20)
        req.setValue("AppUpdater/1.0", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: req)
        let page = r.page.flatMap(URL.init(string:))
        if j.hasSuffix(".yml") {   // latest-mac.yml d'Electron : une ligne « version: 1.2.3 »
            let t = String(decoding: data, as: UTF8.self)
            let lignes = t.split(separator: "\n")
            guard let l = lignes.first(where: { $0.hasPrefix("version:") }) else { throw ErreurSource(L.t("version introuvable", "version not found")) }
            // « path: Signal-8.33.0.dmg » : le fichier, à côté du .yml
            let fichier = lignes.first(where: { $0.hasPrefix("path:") }).map { $0.dropFirst(5).trimmingCharacters(in: .whitespaces) }
            let lien = fichier.flatMap { URL(string: $0, relativeTo: u)?.absoluteURL }
            return Publication(version: l.dropFirst(8).trimmingCharacters(in: .whitespaces), url: lien ?? page, source: .editeur,
                               fichier: installable(lien))
        }
        let racine = try JSONSerialization.jsonObject(with: data)
        guard let v = valeur(racine, r.chemin ?? "version") else { throw ErreurSource(L.t("version introuvable, règle à revoir", "version not found, rule to review")) }
        let lien = r.telechargement.flatMap { valeur(racine, $0) }.flatMap(URL.init(string:))
        return Publication(version: v, url: page ?? lien, source: .editeur, fichier: installable(lien))
    }

    private static func valeur(_ racine: Any, _ chemin: String) -> String? {
        var x: Any? = racine
        for cle in chemin.split(separator: ".") { x = (x as? [String: Any])?[String(cle)] }
        if let s = x as? String { return s }
        if let n = x as? NSNumber { return n.stringValue }
        return nil
    }

    static func github(_ depot: String) async throws -> Publication {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(depot)/releases/latest")!, timeoutInterval: 20)
        req.setValue("AppUpdater/1.0", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: req)
        let j = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard var tag = j?["tag_name"] as? String else { throw ErreurSource((j?["message"] as? String) ?? L.t("dépôt GitHub sans publication", "GitHub repository without release")) }
        if tag.lowercased().hasPrefix("v") { tag.removeFirst() }
        var p = Publication(version: tag, url: (j?["html_url"] as? String).flatMap(URL.init(string:)), source: .github,
                            date: (j?["published_at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) },
                            notes: j?["body"] as? String)
        let fichiers = j?["assets"] as? [[String: Any]] ?? []
        if let f = fichierMac(fichiers), let u = (f["browser_download_url"] as? String).flatMap(URL.init(string:)) {
            p.fichier = u
            // GitHub donne l'empreinte de chaque fichier (« sha256:… ») ; sinon, une liste SHA256SUMS publiée à côté.
            if let d = f["digest"] as? String, d.hasPrefix("sha256:") {
                p.sha256 = String(d.dropFirst(7))
            } else if let somme = fichiers.first(where: { ($0["name"] as? String ?? "").uppercased().contains("SHA256") }),
                      let su = (somme["browser_download_url"] as? String).flatMap(URL.init(string:)),
                      let (d, _) = try? await URLSession.shared.data(from: su) {
                let nom = u.lastPathComponent
                p.sha256 = String(decoding: d, as: UTF8.self).split(separator: "\n")
                    .first { $0.hasSuffix(nom) }?.split(separator: " ").first.map(String.init)
            }
        }
        return p
    }

    /// Parmi les fichiers d'une publication, celui pour un MacBook à puce Apple : .zip de préférence, sinon .dmg ;
    /// arm64 ou universel plutôt qu'Intel.
    private static func fichierMac(_ fichiers: [[String: Any]]) -> [String: Any]? {
        func note(_ n: String) -> Int? {
            let x = n.lowercased()
            guard x.hasSuffix(".zip") || x.hasSuffix(".dmg") else { return nil }
            let autresSystemes = ["win", "linux", "windows"].contains { x.contains($0) }
            let mac = ["mac", "darwin", "osx", "macos"].contains { x.contains($0) }
            if autresSystemes && !mac { return nil }
            let intel = ["x64", "x86", "intel", "amd64"].contains { x.contains($0) }
            let arm = ["arm64", "aarch64", "universal", "apple"].contains { x.contains($0) }
            if intel && !arm { return nil }
            return (arm ? 4 : 0) + (mac ? 2 : 0) + (x.hasSuffix(".zip") ? 1 : 0)
        }
        return fichiers.compactMap { f -> (Int, [String: Any])? in (f["name"] as? String).flatMap(note).map { ($0, f) } }
            .max { $0.0 < $1.0 }?.1
    }
}
