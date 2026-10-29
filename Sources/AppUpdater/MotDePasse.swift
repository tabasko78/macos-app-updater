import AppKit
import Security

/// Réglages > « Mot de passe de session » : combien de temps l'app le retient.
enum MemoireMotDePasse: String, CaseIterable, Identifiable {
    case dixMinutes, session, trousseau
    var id: String { rawValue }
    var libelle: String {
        switch self {
        case .dixMinutes: L.t("10 minutes", "10 minutes")
        case .session: L.t("Jusqu'à la fermeture de l'app", "Until the app quits")
        case .trousseau: L.t("Toujours (trousseau macOS)", "Always (macOS keychain)")
        }
    }
    static var actuelle: MemoireMotDePasse {
        UserDefaults.standard.string(forKey: "memoireMotDePasse").flatMap(MemoireMotDePasse.init(rawValue:)) ?? .dixMinutes
    }
}

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
    /// Mises à jour automatiques : personne n'est devant l'écran, aucune fenêtre ne doit s'ouvrir.
    var silencieux = false
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

    /// Mot de passe refusé par sudo : on le redemandera (et on le retire du trousseau).
    func oublier() {
        verrou.lock(); secret = nil; verrou.unlock()
        Self.trousseau(nil)
    }

    /// Lit le mot de passe rangé dans le trousseau (nil si absent), ou l'y range, ou l'en retire (valeur nil).
    @discardableResult
    static func trousseau(_ valeur: String?, lire: Bool = false) -> String? {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: Dossiers.id + ".session",
                                   kSecAttrAccount as String: NSUserName()]
        if lire {
            var q = base
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var r: AnyObject?
            guard SecItemCopyMatching(q as CFDictionary, &r) == errSecSuccess, let d = r as? Data else { return nil }
            return String(data: d, encoding: .utf8)
        }
        SecItemDelete(base as CFDictionary)
        if let v = valeur {
            var a = base
            a[kSecValueData as String] = Data(v.utf8)
            a[kSecAttrLabel as String] = L.t("Mot de passe de session (macOS App Updater)", "Login password (macOS App Updater)")
            SecItemAdd(a as CFDictionary, nil)
        }
        return nil
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
        let memoire = MemoireMotDePasse.actuelle
        verrou.lock()
        if let s = secret, memoire != .dixMinutes || Date() < expire { verrou.unlock(); return s }
        verrou.unlock()
        if memoire == .trousseau, let s = Self.trousseau(nil, lire: true) {
            verrou.lock(); secret = s; verrou.unlock()
            return s
        }
        if silencieux { return nil }
        var saisi: String?
        DispatchQueue.main.sync { saisi = Self.demander() }
        verrou.lock()
        secret = saisi
        expire = Date().addingTimeInterval(600)
        verrou.unlock()
        if memoire == .trousseau, let s = saisi { Self.trousseau(s) }
        return saisi
    }

    /// Fenêtre de l'app, au premier plan, avec un champ masqué.
    private static func demander() -> String? {
        NSApp.activate(ignoringOtherApps: true)
        let alerte = NSAlert()
        alerte.messageText = L.t("Mot de passe de ta session", "Your login password")
        alerte.informativeText = {
            switch MemoireMotDePasse.actuelle {
            case .dixMinutes: L.t("Homebrew en a besoin pour remplacer l'app. Il est gardé en mémoire 10 minutes, et n'est enregistré nulle part.",
                                  "Homebrew needs it to replace the app. It is kept in memory for 10 minutes, and is never saved.")
            case .session: L.t("Homebrew en a besoin pour remplacer l'app. Il est gardé en mémoire jusqu'à la fermeture de l'app, et n'est enregistré nulle part.",
                               "Homebrew needs it to replace the app. It is kept in memory until the app quits, and is never saved.")
            case .trousseau: L.t("Homebrew en a besoin pour remplacer l'app. Il sera rangé dans le trousseau de macOS et ne sera plus demandé.",
                                 "Homebrew needs it to replace the app. It will be stored in the macOS keychain and not asked again.")
            }
        }()
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
