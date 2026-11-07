import Foundation
import CryptoKit

/// Installation directe, sans Homebrew, pour les apps dont on connaît le fichier de la nouvelle version
/// (publication GitHub, flux de l'éditeur, Sparkle) : télécharger, vérifier, remplacer.
enum Installeur {
    /// Télécharge dans un dossier temporaire propre à cette installation ; `progression` reçoit (fait, total).
    static func telecharger(_ url: URL, progression: @escaping @Sendable (Int64, Int64) -> Void) async throws -> URL {
        try await Telechargeur(progression: progression).lancer(url)
    }

    static func empreinte(_ f: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: f)
        defer { try? h.close() }
        var sha = SHA256()
        while let d = try h.read(upToCount: 4 << 20), !d.isEmpty { sha.update(data: d) }
        return sha.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Sort l'app du .zip ou du .dmg ; renvoie le chemin du .app, à côté du fichier téléchargé.
    static func extraire(_ f: URL) async throws -> URL {
        let fm = FileManager.default
        let dossier = f.deletingLastPathComponent().appendingPathComponent("extrait")
        try fm.createDirectory(at: dossier, withIntermediateDirectories: true)
        switch f.pathExtension.lowercased() {
        case "zip":
            guard await Shell.lancer("/usr/bin/ditto", ["-x", "-k", f.path, dossier.path]).code == 0 else {
                throw ErreurSource(L.t("archive illisible", "unreadable archive"))
            }
        case "dmg":
            let volume = f.deletingLastPathComponent().appendingPathComponent("volume")
            try fm.createDirectory(at: volume, withIntermediateDirectories: true)
            guard await Shell.lancer("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", volume.path, f.path],
                                     delai: 120).code == 0 else {
                throw ErreurSource(L.t("image disque impossible à ouvrir", "could not open the disk image"))
            }
            let app = try? premiereApp(dans: volume)
            if let app { _ = await Shell.lancer("/usr/bin/ditto", [app.path, dossier.appendingPathComponent(app.lastPathComponent).path]) }
            _ = await Shell.lancer("/usr/bin/hdiutil", ["detach", volume.path, "-force"], delai: 60)
            guard app != nil else { throw ErreurSource(L.t("aucune app dans l'image disque", "no app in the disk image")) }
        default:
            throw ErreurSource(L.t("format \(f.pathExtension) non pris en charge", "unsupported format \(f.pathExtension)"))
        }
        return try premiereApp(dans: dossier)
    }

    private static func premiereApp(dans d: URL) throws -> URL {
        let fm = FileManager.default
        let items = try fm.contentsOfDirectory(atPath: d.path)
        if let a = items.first(where: { $0.hasSuffix(".app") }) { return d.appendingPathComponent(a) }
        for i in items {   // un niveau plus bas : certaines archives rangent l'app dans un dossier
            if let sous = try? fm.contentsOfDirectory(atPath: d.appendingPathComponent(i).path),
               let a = sous.first(where: { $0.hasSuffix(".app") }) {
                return d.appendingPathComponent(i).appendingPathComponent(a)
            }
        }
        throw ErreurSource(L.t("aucune app dans le fichier téléchargé", "no app in the downloaded file"))
    }

    /// Refuse tout ce qui ne serait pas la même app, du même éditeur, intacte.
    /// `autreIdentifiant` (libération de l'App Store) : l'éditeur donne parfois un autre identifiant à sa version hors
    /// App Store (The Unarchiver : cx.c3.theunarchiver contre com.macpaw.site.theunarchiver). Accepté seulement si l'app
    /// porte le même nom et que la signature du même éditeur est vérifiée.
    static func controler(_ nouvelle: URL, contre a: AppInstallee, autreIdentifiant: Bool = false) async throws {
        let info = NSDictionary(contentsOfFile: nouvelle.path + "/Contents/Info.plist") as? [String: Any]
        let id = info?["CFBundleIdentifier"] as? String
        let memeNom = nouvelle.lastPathComponent == (a.chemin as NSString).lastPathComponent
        guard id == a.bundleId || (autreIdentifiant && id != nil && memeNom) else {
            throw ErreurSource(L.t("le fichier téléchargé n'est pas \(a.nom)", "the downloaded file is not \(a.nom)"))
        }
        // Une version faite pour l'autre processeur remplacerait une app qui marche par une app qui ne s'ouvre plus.
        if CeMac.tourne(app: nouvelle.path) == false { throw ErreurProcesseur() }
        let avant = await equipe(a.chemin)
        guard avant != nil else {   // l'app installée n'était pas signée par un éditeur : rien à comparer
            if id != a.bundleId { throw ErreurSource(L.t("le fichier téléchargé n'est pas \(a.nom)", "the downloaded file is not \(a.nom)")) }
            return
        }
        guard await Shell.lancer("/usr/bin/codesign", ["--verify", "--deep", "--strict", nouvelle.path], delai: 120).code == 0 else {
            throw ErreurSource(L.t("signature de la nouvelle version invalide", "the new version's signature is invalid"))
        }
        guard await equipe(nouvelle.path) == avant else {
            throw ErreurSource(L.t("la nouvelle version n'est pas signée par le même éditeur", "the new version is not signed by the same developer"))
        }
    }

    /// Identifiant d'équipe Apple du développeur qui a signé l'app, nil si aucun.
    static func equipe(_ app: String) async -> String? {
        let r = await Shell.lancer("/usr/bin/codesign", ["-dv", "--verbose=2", app])
        guard let l = r.sortie.split(separator: "\n").first(where: { $0.hasPrefix("TeamIdentifier=") }) else { return nil }
        let t = String(l.dropFirst("TeamIdentifier=".count))
        return t == "not set" ? nil : t
    }

    /// L'ancienne version part à la Corbeille, la nouvelle prend sa place (mot de passe si l'app appartient au système).
    static func remplacer(_ ancien: String, par nouvelle: URL) async throws {
        let fm = FileManager.default
        guard await Desinstalleur.mettreALaCorbeille([ancien]).isEmpty else {
            throw ErreurSource(L.t("impossible de retirer l'ancienne version", "could not remove the old version"))
        }
        do {
            try fm.moveItem(at: nouvelle, to: URL(fileURLWithPath: ancien))
        } catch {
            let q = { (s: String) in "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            let cmd = "/usr/bin/ditto \(q(nouvelle.path)) \(q(ancien))"
            let script = "do shell script \"\(cmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
            _ = await Shell.lancer("/usr/bin/osascript", ["-e", script], delai: 180)
            guard fm.fileExists(atPath: ancien) else {
                throw ErreurSource(L.t("nouvelle version non posée : l'ancienne est dans la Corbeille, tu peux la remettre en place", "new version not installed: the old one is in the Trash, you can put it back"))
            }
        }
    }

    // MARK: - Paquets .pkg

    /// Équipe Apple qui a signé l'installeur (« Developer ID Installer: … (UBF8T346G9) »), nil s'il ne l'est pas.
    static func equipePaquet(_ f: URL) async -> String? {
        let r = await Shell.lancer("/usr/sbin/pkgutil", ["--check-signature", f.path], delai: 120)
        guard r.code == 0, r.sortie.contains("signed by a developer certificate issued by Apple"),
              let l = r.sortie.split(separator: "\n").first(where: { $0.contains("1. Developer ID Installer:") }),
              let p = l.range(of: #"\(([A-Z0-9]{10})\)\s*$"#, options: .regularExpression) else { return nil }
        return String(l[p]).trimmingCharacters(in: CharacterSet(charactersIn: "() "))
    }

    /// Noms des apps que le paquet pose (« Microsoft Word.app »), lus dans son contenu sans rien installer.
    static func appsDuPaquet(_ f: URL) async -> [String] {
        let r = await Shell.lancer("/usr/sbin/pkgutil", ["--payload-files", f.path], delai: 300)
        var noms: [String] = []
        for l in r.sortie.split(separator: "\n") {
            guard let c = l.split(separator: "/").first(where: { $0.hasSuffix(".app") }), !noms.contains(String(c)) else { continue }
            noms.append(String(c))
        }
        return noms
    }

    /// Remplace l'app par celle du paquet, avec un seul mot de passe administrateur (fenêtre de macOS).
    /// L'ancienne part d'abord en .zip dans la Corbeille : une app du même identifiant laissée telle quelle, même dans
    /// la Corbeille, pourrait attirer l'installeur, que macOS redirige vers une copie déjà connue. Si l'installeur
    /// échoue, elle est remise en place. Renvoie le chemin du .zip.
    static func installerPaquet(_ f: URL, remplace ancien: String) async throws -> String {
        let fm = FileManager.default
        let base = ((ancien as NSString).lastPathComponent as NSString).deletingPathExtension
        var zip = NSHomeDirectory() + "/.Trash/" + base + " (App Store).zip"
        if fm.fileExists(atPath: zip) { zip = NSHomeDirectory() + "/.Trash/" + base + " (App Store) \(Int(Date().timeIntervalSince1970)).zip" }
        let q = { (s: String) in "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let parent = (ancien as NSString).deletingLastPathComponent
        let cmd = "/usr/bin/ditto -c -k --keepParent \(q(ancien)) \(q(zip)) && /usr/sbin/chown \(q(NSUserName())) \(q(zip)) && /bin/rm -rf \(q(ancien))"
            + " && { /usr/sbin/installer -pkg \(q(f.path)) -target / || { /usr/bin/ditto -x -k \(q(zip)) \(q(parent)); exit 1; }; }"
        let script = "do shell script \"\(cmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
        let r = await Shell.lancer("/usr/bin/osascript", ["-e", script], delai: 1800)
        guard r.code == 0 else {
            throw ErreurSource(fm.fileExists(atPath: ancien)
                ? L.t("installation refusée ou annulée, l'app en place n'a pas changé", "installation refused or cancelled, the installed app is unchanged")
                : L.t("installation échouée, l'ancienne version est dans la Corbeille (\((zip as NSString).lastPathComponent))", "installation failed, the old version is in the Trash (\((zip as NSString).lastPathComponent))"))
        }
        return zip
    }

    static func nettoyer(_ fichier: URL) {
        try? FileManager.default.removeItem(at: fichier.deletingLastPathComponent())
    }
}

/// La nouvelle version ne peut pas s'ouvrir sur ce Mac : l'installation s'arrête avant de toucher à l'app en place,
/// et cette version n'est plus proposée ici.
struct ErreurProcesseur: Error, LocalizedError {
    var errorDescription: String? { L.t("nouvelle version ", "new version ") + CeMac.raisonProcesseur + L.t(" : rien n'a été remplacé", ": nothing was replaced") }
}

/// Téléchargement avec suivi de progression (URLSession ne la donne qu'à un délégué).
final class Telechargeur: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progression: @Sendable (Int64, Int64) -> Void
    private var suite: CheckedContinuation<URL, Error>?
    private var nom = "fichier"

    init(progression: @escaping @Sendable (Int64, Int64) -> Void) { self.progression = progression }

    func lancer(_ url: URL) async throws -> URL {
        nom = url.lastPathComponent
        return try await withCheckedThrowingContinuation { c in
            suite = c
            let s = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
            s.downloadTask(with: url).resume()
            s.finishTasksAndInvalidate()
        }
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                    totalBytesWritten fait: Int64, totalBytesExpectedToWrite total: Int64) {
        progression(fait, total)
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo lieu: URL) {
        if let h = downloadTask.response as? HTTPURLResponse, h.statusCode >= 400 {
            finir(.failure(ErreurSource(L.t("le serveur a répondu \(h.statusCode)", "the server answered \(h.statusCode)"))))
            return
        }
        // Le fichier temporaire d'URLSession disparaît au retour de cette fonction : on le déplace tout de suite.
        var nomFinal = downloadTask.response?.suggestedFilename ?? nom
        if !["zip", "dmg"].contains((nomFinal as NSString).pathExtension.lowercased()) { nomFinal = nom }
        let dossier = FileManager.default.temporaryDirectory.appendingPathComponent("misesajour-" + UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: dossier, withIntermediateDirectories: true)
            let dest = dossier.appendingPathComponent(nomFinal)
            try FileManager.default.moveItem(at: lieu, to: dest)
            finir(.success(dest))
        } catch {
            finir(.failure(error))
        }
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError e: Error?) {
        if let e { finir(.failure(e)) }
    }

    private func finir(_ r: Result<URL, Error>) {
        guard let c = suite else { return }
        suite = nil
        c.resume(with: r)
    }
}
