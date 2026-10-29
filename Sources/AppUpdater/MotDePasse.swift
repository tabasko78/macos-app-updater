import AppKit

/// Le mot de passe que Homebrew demande pour ses étapes en sudo, demandé une seule fois puis gardé en mémoire
/// 10 minutes : un lot de mises à jour (et chaque sudo d'une même mise à jour) ne le redemande plus.
///
/// Homebrew lance `sudo -A`, qui appelle le script SUDO_ASKPASS ; ce script lit un tube nommé (FIFO) dans le
/// dossier de l'app, accessible au seul compte. L'app y écrit le mot de passe à chaque lecture : il ne passe
/// jamais par le disque, ni par une variable d'environnement.
final class MotDePasse: @unchecked Sendable {
    static let partage = MotDePasse()

    private let verrou = NSLock()
    private var secret: String?
    private var expire = Date.distantPast
    private var lance = false
    private let tube = Dossiers.support.appendingPathComponent("mot-de-passe.fifo").path
    private let script = Dossiers.support.appendingPathComponent("demande-mot-de-passe.sh").path

    /// Chemin du script à donner à SUDO_ASKPASS ; met en place le tube et le fil qui y répond.
    func askpass() -> String {
        verrou.lock(); defer { verrou.unlock() }
        if !lance {
            unlink(tube)
            mkfifo(tube, 0o600)
            try? "#!/bin/zsh\n/bin/cat \"\(tube)\"\n".write(toFile: script, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script)
            let fil = Thread { [unowned self] in self.servir() }
            fil.name = "mot-de-passe"
            fil.start()
            lance = true
        }
        return script
    }

    /// Mot de passe refusé par sudo : on le redemandera.
    func oublier() {
        verrou.lock(); secret = nil; verrou.unlock()
    }

    private func servir() {
        while true {
            let fd = open(tube, O_WRONLY)   // attend qu'un askpass lise
            guard fd >= 0 else { Thread.sleep(forTimeInterval: 1); continue }
            let mdp = (obtenir() ?? "") + "\n"
            mdp.withCString { _ = write(fd, $0, strlen($0)) }
            close(fd)
        }
    }

    private func obtenir() -> String? {
        verrou.lock()
        if let s = secret, Date() < expire { verrou.unlock(); return s }
        verrou.unlock()
        var saisi: String?
        DispatchQueue.main.sync { saisi = Self.demander() }
        verrou.lock()
        secret = saisi
        expire = Date().addingTimeInterval(600)
        verrou.unlock()
        return saisi
    }

    /// Fenêtre de l'app, au premier plan, avec un champ masqué.
    private static func demander() -> String? {
        NSApp.activate(ignoringOtherApps: true)
        let alerte = NSAlert()
        alerte.messageText = L.t("Mot de passe de ta session", "Your login password")
        alerte.informativeText = L.t("Homebrew en a besoin pour remplacer l'app. Il est gardé en mémoire 10 minutes, le temps des mises à jour, et n'est enregistré nulle part.",
                                     "Homebrew needs it to replace the app. It is kept in memory for 10 minutes, during the updates, and is never saved.")
        alerte.addButton(withTitle: "OK")
        alerte.addButton(withTitle: L.t("Annuler", "Cancel"))
        let champ = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        alerte.accessoryView = champ
        alerte.window.initialFirstResponder = champ
        alerte.window.level = .floating
        guard alerte.runModal() == .alertFirstButtonReturn, !champ.stringValue.isEmpty else { return nil }
        return champ.stringValue
    }
}
