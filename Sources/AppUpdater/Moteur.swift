import AppKit
import ServiceManagement
import UserNotifications

@MainActor
final class Moteur: ObservableObject {
    @Published var apps: [AppInstallee] = []
    @Published var enCours = false
    @Published var derniereVerif: Date?
    @Published var message: String?
    @Published var sortieBrew = ""
    @Published var progression: [String: Double] = [:]   // id de l'app → 0…1, -1 tant que la taille est inconnue
    @Published var etape: [String: String] = [:]         // id de l'app → texte affiché sous la barre
    @Published var lot: (fait: Int, total: Int)?
    @Published var ignorees: [String: String]           // bundle id → version ignorée
    @Published var nonSuivies: Set<String>              // bundle id
    @Published var lancementSession: Bool
    @Published var historique: [EntreeJournal]
    @Published var aDesinstaller: AppInstallee?
    @Published var tailles: [String: Int64] = [:]       // chemin → octets occupés sur le disque
    @Published var selection: Set<String> = []          // ids des apps cochées
    var montrerFenetre: (() -> Void)?
    @Published var hauteurFenetre: CGFloat = 0           // hauteur naturelle du contenu de la fenêtre                   // posé par le Delegue, qui tient la fenêtre

    @Published var theme: ThemeNom { didSet { reglages.set(theme.rawValue, forKey: "theme") } }
    @Published var langue: Langue {
        didSet {
            reglages.set(langue.rawValue, forKey: "langue")
            apps = apps.map { Verification.resoudre($0, contexte) }   // les remarques sont écrites dans la langue choisie
        }
    }
    @Published var frequence: Int { didSet { reglages.set(frequence, forKey: "frequence"); planifier() } }   // en heures
    @Published var notifications: Bool { didSet { reglages.set(notifications, forKey: "notifications") } }
    @Published var affichage: Affichage {
        didSet { reglages.set(affichage.rawValue, forKey: "affichage"); appliquerAffichage?() }
    }
    var appliquerAffichage: (() -> Void)?                // posé par le Delegue, qui tient l'icône et le Dock

    private var contexte = Contexte()
    private var notifiees: Set<String>
    private var minuteur: Timer?
    private var surveillances: [DispatchSourceFileSystemObject] = []
    private var relecture: Task<Void, Never>?
    private let reglages = UserDefaults.standard

    init() {
        ignorees = reglages.dictionary(forKey: "ignorees") as? [String: String] ?? [:]
        nonSuivies = Set(reglages.stringArray(forKey: "nonSuivies") ?? [])
        notifiees = Set(reglages.stringArray(forKey: "notifiees") ?? [])
        // Ouverture à la connexion : macOS la rattache à l'emplacement de l'app. Si l'app a été déplacée
        // (dans /Applications par exemple), on la réinscrit depuis son nouvel emplacement.
        let voulu = reglages.object(forKey: "ouvrirConnexion") as? Bool ?? (SMAppService.mainApp.status == .enabled)
        if voulu && SMAppService.mainApp.status != .enabled { try? SMAppService.mainApp.register() }
        lancementSession = SMAppService.mainApp.status == .enabled
        historique = Historique.journal()
        theme = T.nom
        langue = L.choix
        frequence = reglages.object(forKey: "frequence") as? Int ?? 6
        notifications = reglages.object(forKey: "notifications") as? Bool ?? true
        affichage = reglages.string(forKey: "affichage").flatMap(Affichage.init(rawValue:)) ?? .menu
        planifier()
        surveillerApplications()
        Task { await verifier() }
    }

    /// Une app ajoutée, remplacée ou supprimée dans /Applications relance la vérification 5 s plus tard,
    /// sauf pendant une mise à jour ou une désinstallation faite ici (l'app y disparaît un instant).
    private func surveillerApplications() {
        for d in ["/Applications", NSHomeDirectory() + "/Applications"] {
            let fd = open(d, O_EVTONLY)
            guard fd >= 0 else { continue }
            let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
            s.setEventHandler { [weak self] in Task { @MainActor in self?.relireBientot() } }
            s.setCancelHandler { close(fd) }
            s.resume()
            surveillances.append(s)
        }
    }

    private func relireBientot() {
        relecture?.cancel()
        relecture = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, !Task.isCancelled else { return }
            if !self.progression.isEmpty || self.lot != nil || self.aDesinstaller != nil || self.enCours {
                self.relireBientot()
                return
            }
            await self.verifier()
        }
    }

    private func planifier() {
        minuteur?.invalidate()
        minuteur = Timer.scheduledTimer(withTimeInterval: Double(frequence) * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.verifier() }
        }
    }

    // MARK: - Listes

    func estIgnoree(_ a: AppInstallee) -> Bool {
        nonSuivies.contains(a.bundleId) || (a.disponible != nil && ignorees[a.bundleId] == a.disponible)
    }

    var aMettreAJour: [AppInstallee] { apps.filter { $0.aJour == false && !estIgnoree($0) } }

    // MARK: - Vérification

    func verifier() async {
        guard !enCours else { return }
        enCours = true
        let r = await Verification.tout()
        contexte = r.contexte
        apps = r.apps.sorted { $0.nom.localizedCaseInsensitiveCompare($1.nom) == .orderedAscending }
        message = r.erreurs.isEmpty ? nil : r.erreurs.joined(separator: " · ")
        derniereVerif = Date()
        let restantes = Set(cochables.map(\.id))
        selection = selection.intersection(restantes)
        enCours = false
        comparerAvecLaDerniereFois()
        notifier()
        mesurerTailles()
    }

    /// Mesure en arrière-plan, app par app ; seules les apps nouvelles ou changées de version sont remesurées.
    private func mesurerTailles() {
        let liste = apps.map { ($0.chemin, $0.versionAffichee + "|" + $0.build) }
        Task.detached(priority: .utility) { [weak self] in
            let ancien = Tailles.lire()
            var cache: [String: Tailles.Entree] = [:]
            var connues: [String: Int64] = [:]
            for (c, v) in liste {
                if let e = ancien[c], e.version == v { cache[c] = e; connues[c] = e.taille }
            }
            let deja = connues
            await MainActor.run { self?.tailles = deja }
            for (c, v) in liste where cache[c] == nil {
                let t = Desinstalleur.taille(c)
                cache[c] = .init(version: v, taille: t)
                await MainActor.run { self?.tailles[c] = t }
            }
            Tailles.ecrire(cache)
        }
    }

    /// Ce qui a changé depuis la vérification précédente sans passer par l'app : App Store, mise à jour
    /// interne de l'app, installation ou suppression à la main.
    private func comparerAvecLaDerniereFois() {
        let avant = Historique.versionsVues()
        var maintenant: [String: String] = [:]
        for a in apps { maintenant[a.chemin] = a.nom + "|" + a.versionAffichee }
        if !avant.isEmpty {
            var nouvelles: [EntreeJournal] = []
            for a in apps {
                if let v = avant[a.chemin] {
                    let ancienne = String(v.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).last ?? "")
                    if ancienne != a.versionAffichee {
                        nouvelles.append(.init(date: Date(), nom: a.nom, bundleId: a.bundleId, avant: ancienne, apres: a.versionAffichee, quoi: "Mise à jour", par: "hors de l'app"))
                    }
                } else {
                    nouvelles.append(.init(date: Date(), nom: a.nom, bundleId: a.bundleId, avant: nil, apres: a.versionAffichee, quoi: "Installée", par: "hors de l'app"))
                }
            }
            for (chemin, v) in avant where maintenant[chemin] == nil {
                let morceaux = v.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                nouvelles.append(.init(date: Date(), nom: morceaux.first ?? chemin, bundleId: "", avant: morceaux.last, apres: nil, quoi: "Disparue", par: "hors de l'app"))
            }
            noter(nouvelles)
        }
        Historique.enregistrer(versions: maintenant)
    }

    private func noter(_ e: [EntreeJournal]) {
        guard !e.isEmpty else { return }
        historique.insert(contentsOf: e, at: 0)
        Historique.enregistrer(historique)
    }

    private func retenirVersion(_ a: AppInstallee) {
        var v = Historique.versionsVues()
        v[a.chemin] = a.nom + "|" + a.versionAffichee
        Historique.enregistrer(versions: v)
    }

    private func remplacer(_ a: AppInstallee) {
        if let i = apps.firstIndex(where: { $0.id == a.id }) { apps[i] = a }
    }

    // MARK: - Réglages par app

    func ignorer(_ a: AppInstallee) {
        guard let v = a.disponible else { return }
        ignorees[a.bundleId] = v
        reglages.set(ignorees, forKey: "ignorees")
    }

    func neplusIgnorer(_ a: AppInstallee) {
        ignorees[a.bundleId] = nil
        nonSuivies.remove(a.bundleId)
        reglages.set(ignorees, forKey: "ignorees")
        reglages.set(Array(nonSuivies), forKey: "nonSuivies")
    }

    /// Clic droit « Classer comme » ; nil revient au classement automatique.
    func classer(_ a: AppInstallee, _ c: Classement?) {
        var d = reglages.dictionary(forKey: "classements") as? [String: String] ?? [:]
        d[a.bundleId] = c?.rawValue
        reglages.set(d, forKey: "classements")
        contexte.classements = d
        apps = apps.map { Verification.resoudre($0, contexte) }
    }

    func nePlusSuivre(_ a: AppInstallee) {
        nonSuivies.insert(a.bundleId)
        reglages.set(Array(nonSuivies), forKey: "nonSuivies")
    }

    func basculerLancementSession(_ oui: Bool) {
        do {
            if oui { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            message = L.t("Ouverture de session : \(error.localizedDescription)", "Open at login: \(error.localizedDescription)")
        }
        lancementSession = SMAppService.mainApp.status == .enabled
        reglages.set(oui, forKey: "ouvrirConnexion")
    }

    func ouvrir(_ a: AppInstallee, auPremierPlan: Bool = true) {
        let c = NSWorkspace.OpenConfiguration()
        c.activates = auPremierPlan
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: a.chemin), configuration: c) { _, erreur in
            guard let erreur else { return }
            Task { @MainActor [weak self] in self?.message = L.t("Impossible d'ouvrir \(a.nom) : \(erreur.localizedDescription)", "Could not open \(a.nom): \(erreur.localizedDescription)") }
        }
    }

    // MARK: - Mise à jour

    func mettreAJour(_ a: AppInstallee) async {
        switch a.action {
        case .appStore(let u):
            var c = URLComponents(url: u, resolvingAgainstBaseURL: false)
            c?.scheme = "macappstore"
            NSWorkspace.shared.open(c?.url ?? u)
        case .telecharger(let u), .page(let u):
            NSWorkspace.shared.open(u)
        case .ouvrirApp:
            ouvrir(a)
        case .brew(let token, let terminal):
            _ = terminal
            await brew(a, token: token)
        case .installer(let u, let sha):
            await installerDirect(a, u, sha)
        case .aucune:
            break
        }
    }

    /// Toutes, comme si tout était coché : Homebrew installe, les autres ouvrent leur App Store, leur page ou le Terminal.
    func toutMettreAJour() async {
        await enLot(cochables)
    }

    // MARK: - Cases à cocher

    /// Les apps qu'on peut cocher : une mise à jour existe et un bouton sait la lancer.
    var cochables: [AppInstallee] { aMettreAJour.filter { $0.action != .aucune } }

    func basculer(_ a: AppInstallee) {
        if selection.contains(a.id) { selection.remove(a.id) } else { selection.insert(a.id) }
    }

    func toutCocher(_ oui: Bool) {
        selection = oui ? Set(cochables.map(\.id)) : []
    }

    /// Les apps cochées, dans l'ordre de la liste : Homebrew installe, les autres ouvrent leur App Store ou leur page.
    func mettreAJourSelection() async {
        await enLot(cochables.filter { selection.contains($0.id) })
    }

    private func enLot(_ liste: [AppInstallee]) async {
        guard !liste.isEmpty, lot == nil else { return }
        lot = (0, liste.count)
        for a in liste {
            await mettreAJour(a)
            selection.remove(a.id)
            lot = (lot!.fait + 1, liste.count)
        }
        lot = nil
    }

    /// Ferme l'app si elle tourne, après l'avoir proposé (sauf « Ne plus demander »). Si elle refuse de se fermer
    /// (Chrome, Firefox… qui attendent une confirmation), propose de forcer la fermeture.
    /// Renvoie nil si elle n'est pas fermée (refus ou annulation), sinon si elle tournait.
    private func fermer(_ a: AppInstallee, pour geste: String? = nil) async -> Bool? {
        let ouvertes = NSRunningApplication.runningApplications(withBundleIdentifier: a.bundleId)
            .filter { $0.bundleURL?.path == a.chemin }
        guard !ouvertes.isEmpty else { return false }
        let pourquoi = geste ?? L.t("Pour la mettre à jour, il faut la fermer. Elle sera rouverte ensuite.",
                                    "It has to quit to be updated. It will be reopened afterwards.")
        if !reglages.bool(forKey: "fermerSansDemander") {
            let r = demander(L.t("\(a.nom) est ouverte", "\(a.nom) is open"), pourquoi,
                             [L.t("Fermer et continuer", "Quit and continue"), L.t("Annuler", "Cancel")],
                             caseACocher: L.t("Fermer les apps sans demander", "Quit apps without asking"))
            if r.coche { reglages.set(true, forKey: "fermerSansDemander") }
            guard r.bouton == 0 else { message = L.t("\(a.nom) : annulé", "\(a.nom): cancelled"); return nil }
        }
        ouvertes.forEach { $0.terminate() }
        while true {
            for _ in 0..<24 where ouvertes.contains(where: { !$0.isTerminated }) {
                try? await Task.sleep(for: .milliseconds(500))
            }
            if !ouvertes.contains(where: { !$0.isTerminated }) { return true }
            let r = demander(L.t("\(a.nom) ne se ferme pas", "\(a.nom) does not quit"),
                             L.t("Elle attend peut-être une confirmation (onglets ouverts, document non enregistré) : regarde ses fenêtres. Tu peux aussi forcer la fermeture, ce qui n'est pas enregistré sera perdu.",
                                 "It may be waiting for a confirmation (open tabs, unsaved document): check its windows. You can also force it to quit; anything unsaved will be lost."),
                             [L.t("Attendre encore", "Wait more"), L.t("Forcer la fermeture", "Force quit"), L.t("Annuler", "Cancel")])
            switch r.bouton {
            case 0: continue
            case 1:
                ouvertes.forEach { _ = $0.forceTerminate() }
                for _ in 0..<10 where ouvertes.contains(where: { !$0.isTerminated }) { try? await Task.sleep(for: .milliseconds(500)) }
                if !ouvertes.contains(where: { !$0.isTerminated }) { return true }
                message = L.t("\(a.nom) ne s'est pas fermée, ferme-la puis recommence", "\(a.nom) did not quit; quit it and try again")
                return nil
            default:
                message = L.t("\(a.nom) : annulé", "\(a.nom): cancelled")
                return nil
            }
        }
    }

    /// Fenêtre de question au premier plan ; renvoie le bouton choisi (0 = le premier) et la case.
    private func demander(_ titre: String, _ texte: String, _ boutons: [String], caseACocher: String? = nil) -> (bouton: Int, coche: Bool) {
        NSApp.activate(ignoringOtherApps: true)
        let alerte = NSAlert()
        alerte.messageText = titre
        alerte.informativeText = texte
        boutons.forEach { alerte.addButton(withTitle: $0) }
        if let caseACocher {
            alerte.showsSuppressionButton = true
            alerte.suppressionButton?.title = caseACocher
        }
        let r = alerte.runModal()
        return (r.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue, alerte.suppressionButton?.state == .on)
    }

    /// Une étape de la mise à jour : la barre avance d'elle-même de `debut` vers `fin` (sans jamais l'atteindre)
    /// tant que l'étape dure, et saute au début de l'étape suivante dès qu'elle commence.
    private struct Phase {
        let texte: String
        let debut: Double
        let fin: Double
    }
    private static let fermeture = Phase(texte: L.t("Fermeture de l'app…", "Quitting the app…"), debut: 0, fin: 0.04)
    private static let preparation = Phase(texte: L.t("Préparation par Homebrew…", "Homebrew is getting ready…"), debut: 0.04, fin: 0.14)
    private static let telechargementPhase = Phase(texte: L.t("Téléchargement…", "Downloading…"), debut: 0.14, fin: 0.74)
    private static let verificationPhase = Phase(texte: L.t("Vérification du fichier…", "Checking the file…"), debut: 0.76, fin: 0.82)
    private static let installationPhase = Phase(texte: L.t("Installation…", "Installing…"), debut: 0.82, fin: 0.97)
    private var phases: [String: Phase] = [:]

    private func entrer(_ p: Phase, _ id: String) {
        guard (phases[id]?.debut ?? -1) < p.debut else { return }   // jamais de retour en arrière
        phases[id] = p
        etape[id] = p.texte
        progression[id] = max(progression[id] ?? 0, p.debut)
    }

    private func brew(_ a: AppInstallee, token: String) async {
        guard Homebrew.present else { message = L.t("Homebrew est introuvable dans /opt/homebrew", "Homebrew was not found in /opt/homebrew"); return }
        let id = a.id
        entrer(Self.fermeture, id)
        let suivi = suivre(id, url: a.cask?.url, homebrew: true)
        defer { suivi.cancel(); progression[id] = nil; etape[id] = nil; phases[id] = nil }

        guard let tournait = await fermer(a) else { return }
        entrer(Self.preparation, id)

        let args = contexte.casksInstalles.contains(token)
            ? ["upgrade", "--cask", "--greedy", token]
            : ["install", "--cask", "--force", token]
        sortieBrew += "\n$ brew \(args.joined(separator: " "))\n"
        // Lancé dans un terminal simulé (script) : sans lui, Homebrew garde tout ce qu'il écrit
        // jusqu'à la fin, et les étapes n'arrivent qu'une fois l'installation terminée.
        // HOMEBREW_AUTO_UPDATE_SECS : Homebrew rafraîchit son catalogue s'il a plus de 5 min. Par défaut il attend
        // 24 h, et réinstallait alors l'ancienne version (Signal 8.32.0 « mis à jour » en 8.32.0 le 29/10/2026).
        let r = await Shell.lancer("/usr/bin/script", ["-q", "/dev/null", Homebrew.chemin] + args,
                                   env: ["HOMEBREW_AUTO_UPDATE_SECS": "300", "SUDO_ASKPASS": Self.demandeMotDePasse()]) { morceau in
            Task { @MainActor [weak self] in self?.lireSortie(morceau, id) }
        }
        if r.code == 0, let n = Inventaire.lire(chemin: a.chemin) {
            progression[id] = 1
            etape[id] = L.t("Terminé", "Done")
            contexte.casksInstalles.insert(token)
            if let v = a.cask?.version { contexte.versionsBrew[token] = v }
            let nouvelle = Verification.resoudre(n, contexte)
            remplacer(nouvelle)
            let quoi = nouvelle.versionAffichee == a.versionAffichee ? "Réinstallée" : "Mise à jour"
            noter([.init(date: Date(), nom: a.nom, bundleId: a.bundleId, avant: a.versionAffichee, apres: nouvelle.versionAffichee, quoi: quoi, par: "Homebrew")])
            retenirVersion(nouvelle)
            mesurerTailles()
            message = quoi == "Réinstallée" && nouvelle.aJour == false
                ? L.t("Homebrew n'a pas encore la version \(nouvelle.disponible ?? "annoncée") de \(a.nom), réessaie plus tard", "Homebrew does not have \(a.nom) \(nouvelle.disponible ?? "") yet, try again later")
                : L.t("\(a.nom) mise à jour", "\(a.nom) updated")
            try? await Task.sleep(for: .milliseconds(600))   // laisser voir la barre pleine
        } else {
            message = L.t("Échec de la mise à jour de \(a.nom), le détail est dans la sortie Homebrew", "Updating \(a.nom) failed, see the Homebrew output")
        }
        if tournait { ouvrir(a, auPremierPlan: false) }   // rouverte en arrière-plan : on reste dans Mises à jour
    }

    /// Sans Homebrew : télécharger le fichier, vérifier empreinte et signature, fermer l'app, la remplacer, la rouvrir.
    private func installerDirect(_ a: AppInstallee, _ url: URL, _ sha: String?) async {
        let id = a.id
        entrer(Self.preparation, id)
        let suivi = suivre(id, url: nil, homebrew: false)
        var fichier: URL?
        defer {
            suivi.cancel(); progression[id] = nil; etape[id] = nil; phases[id] = nil
            if let fichier { Installeur.nettoyer(fichier) }
        }
        sortieBrew += "\n# \(a.nom) : \(url.absoluteString)\n"
        do {
            entrer(Self.telechargementPhase, id)
            let f = try await Installeur.telecharger(url) { fait, total in
                Task { @MainActor [weak self] in self?.avancerTelechargement(id, fait, total) }
            }
            fichier = f
            entrer(Self.verificationPhase, id)
            if let sha {
                guard try Installeur.empreinte(f) == sha.lowercased() else { throw ErreurSource(L.t("empreinte du fichier incorrecte, téléchargement refusé", "wrong file hash, download rejected")) }
                sortieBrew += L.t("empreinte vérifiée", "hash verified") + "\n"
            }
            let nouvelle = try await Installeur.extraire(f)
            try await Installeur.controler(nouvelle, contre: a)
            sortieBrew += L.t("signature contrôlée", "signature checked") + "\n"
            entrer(Self.installationPhase, id)
            guard let tournait = await fermer(a) else { throw ErreurSource(message ?? L.t("annulé", "cancelled")) }
            try await Installeur.remplacer(a.chemin, par: nouvelle)
            progression[id] = 1
            etape[id] = L.t("Terminé", "Done")
            if let n = Inventaire.lire(chemin: a.chemin) {
                let r = Verification.resoudre(n, contexte)
                remplacer(r)
                noter([.init(date: Date(), nom: a.nom, bundleId: a.bundleId, avant: a.versionAffichee, apres: r.versionAffichee, quoi: "Mise à jour", par: a.source.rawValue)])
                retenirVersion(r)
                mesurerTailles()
            }
            sortieBrew += L.t("installée", "installed") + "\n"
            message = L.t("\(a.nom) mise à jour", "\(a.nom) updated")
            if tournait { ouvrir(a, auPremierPlan: false) }
            try? await Task.sleep(for: .milliseconds(600))
        } catch {
            sortieBrew += L.t("échec : ", "failed: ") + error.localizedDescription + "\n"
            message = L.t("Échec de la mise à jour de \(a.nom) : \(error.localizedDescription)", "Updating \(a.nom) failed: \(error.localizedDescription)")
        }
    }

    private func avancerTelechargement(_ id: String, _ fait: Int64, _ total: Int64) {
        guard phases[id]?.debut == Self.telechargementPhase.debut else { return }
        let t = Self.telechargementPhase
        if total > 0 {
            let x = min(1, Double(fait) / Double(total))
            progression[id] = t.debut + x * (t.fin - t.debut)
            etape[id] = L.t("Téléchargement \(Int(x * 100)) % · \(Desinstalleur.lisible(fait)) sur \(Desinstalleur.lisible(total))", "Downloading \(Int(x * 100)) % · \(Desinstalleur.lisible(fait)) of \(Desinstalleur.lisible(total))")
        } else {
            etape[id] = L.t("Téléchargement · \(Desinstalleur.lisible(fait))", "Downloading · \(Desinstalleur.lisible(fait))")
        }
    }

    /// Nettoie ce qu'écrit Homebrew (codes du terminal simulé) et en déduit l'étape.
    private func lireSortie(_ brut: String, _ id: String) {
        let propre = brut
            .replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{04}", with: "")
            .replacingOccurrences(of: "\u{08}", with: "")
        let lignes = propre.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        for l in lignes {
            // Le terminal simulé redessine la même ligne plusieurs fois : une seule copie dans la sortie.
            if !sortieBrew.hasSuffix(l + "\n") { sortieBrew += l + "\n" }
            if l.contains("==> Fetching") || l.contains("==> Downloading") {
                entrer(Self.telechargementPhase, id)
            } else if l.hasPrefix("✔") || l.contains("Already downloaded") || l.contains("Verifying") {
                entrer(Self.verificationPhase, id)
            } else if ["==> Installing", "==> Upgrading", "==> Moving", "==> Removing", "==> Backing", "==> Purging",
                       "==> Uninstalling", "==> Running installer"].contains(where: { l.contains($0) }) {
                entrer(Self.installationPhase, id)
            }
        }
    }

    /// Fait vivre la barre toutes les 0,25 s : pendant le téléchargement, la taille du fichier .incomplete que
    /// Homebrew remplit dans ~/Library/Caches/Homebrew/downloads, rapportée à la taille annoncée par le
    /// serveur ; pendant les autres étapes, une avance lente vers la fin de l'étape.
    private func suivre(_ id: String, url: String?, homebrew: Bool) -> Task<Void, Never> {
        Task { [weak self] in
            var total: Int64 = 0
            if let s = url, let u = URL(string: s) {
                var req = URLRequest(url: u, timeoutInterval: 10)
                req.httpMethod = "HEAD"
                if let (_, rep) = try? await URLSession.shared.data(for: req) { total = max(0, rep.expectedContentLength) }
            }
            let dossier = NSHomeDirectory() + "/Library/Caches/Homebrew/downloads"
            let debut = Date().addingTimeInterval(-2)
            var vuEnCours = false
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, let phase = self.phases[id], let p = self.progression[id] else { continue }
                // Installation directe : le téléchargement donne sa vraie progression, pas d'avance simulée pendant.
                if !homebrew && phase.debut == Self.telechargementPhase.debut { continue }
                let fait = homebrew ? Moteur.tailleEnCours(dossier, depuis: debut) : nil
                if let fait {
                    // Un fichier en cours de téléchargement : c'est la meilleure mesure qui soit.
                    vuEnCours = true
                    self.entrer(Self.telechargementPhase, id)
                    let t = Self.telechargementPhase
                    if total > 0 {
                        let x = min(1, Double(fait) / Double(total))
                        self.progression[id] = max(p, t.debut + x * (t.fin - t.debut))
                        self.etape[id] = L.t("Téléchargement \(Int(x * 100)) % · \(Desinstalleur.lisible(fait)) sur \(Desinstalleur.lisible(total))", "Downloading \(Int(x * 100)) % · \(Desinstalleur.lisible(fait)) of \(Desinstalleur.lisible(total))")
                    } else {
                        self.progression[id] = p + (t.fin - p) * 0.02
                        self.etape[id] = L.t("Téléchargement · \(Desinstalleur.lisible(fait))", "Downloading · \(Desinstalleur.lisible(fait))")
                    }
                    continue
                }
                if vuEnCours && phase.debut <= Self.telechargementPhase.debut {
                    // Le fichier a fini de se télécharger (renommé) : on passe à la vérification.
                    self.entrer(Self.verificationPhase, id)
                    continue
                }
                self.progression[id] = p + (phase.fin - p) * 0.025
            }
        }
    }

    nonisolated static func tailleEnCours(_ dossier: String, depuis: Date) -> Int64? {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: dossier) else { return nil }
        let candidats = items.filter { $0.hasSuffix(".incomplete") }.compactMap { i -> (Date, Int64)? in
            guard let at = try? fm.attributesOfItem(atPath: dossier + "/" + i),
                  let d = at[.modificationDate] as? Date, d > depuis,
                  let t = at[.size] as? NSNumber else { return nil }
            return (d, t.int64Value)
        }
        return candidats.max { $0.0 < $1.0 }?.1
    }

    /// Homebrew passe parfois par sudo (paquets .pkg, services à arrêter comme ShipIt de Visual Studio Code).
    /// Sans terminal, sudo attendait un mot de passe que personne ne pouvait taper et la mise à jour ne finissait
    /// jamais (29/10/2026). Avec SUDO_ASKPASS, Homebrew appelle `sudo -A`, qui demande le mot de passe par ce
    /// script : une fenêtre macOS standard, rien n'est gardé.
    static func demandeMotDePasse() -> String {
        let f = Dossiers.support.appendingPathComponent("demande-mot-de-passe.sh")
        let invite = L.t("Homebrew a besoin du mot de passe de ta session pour terminer la mise à jour.",
                         "Homebrew needs your login password to finish the update.")
        let script = """
        #!/bin/zsh
        /usr/bin/osascript -e 'display dialog "\(invite.replacingOccurrences(of: "'", with: "’"))" with title "\(L.t("Mises à jour", "App Updater"))" default answer "" with hidden answer with icon caution buttons {"\(L.t("Annuler", "Cancel"))", "OK"} default button "OK"' -e 'text returned of result'
        """
        try? script.write(to: f, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: f.path)
        return f.path
    }

    /// Les paquets .pkg demandent le mot de passe administrateur : seul un vrai Terminal peut le recevoir.
    private func ouvrirDansTerminal(_ a: AppInstallee, token: String) {
        let script = """
        #!/bin/zsh
        echo L.t("Mise à jour de \(a.nom) par Homebrew. Le mot de passe demandé est celui de ta session.", "Updating \(a.nom) with Homebrew. The password asked for is your login password.")
        echo
        HOMEBREW_AUTO_UPDATE_SECS=300 /opt/homebrew/bin/brew install --cask --force \(token)
        echo
        echo L.t("Terminé, cette fenêtre peut être fermée. Relance la vérification dans Mises à jour.", "Done, you can close this window. Run the check again in the app.")
        """
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("misesajour-\(token).command")
        do {
            try script.write(to: f, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.path)
            NSWorkspace.shared.open(f)
        } catch {
            message = L.t("Impossible d'ouvrir le Terminal : \(error.localizedDescription)", "Could not open Terminal: \(error.localizedDescription)")
        }
    }

    // MARK: - Désinstallation

    func preparerDesinstallation(chemin: String) {
        if let a = apps.first(where: { $0.chemin == chemin }) ?? Inventaire.lire(chemin: chemin) {
            aDesinstaller = a
        } else {
            message = L.t("Les apps d'Apple ne se désinstallent pas ici", "Apple apps cannot be uninstalled here")
        }
    }

    /// Renvoie un message d'erreur, ou nil si tout est parti à la Corbeille.
    func desinstaller(_ a: AppInstallee, _ chemins: [String]) async -> String? {
        guard await fermer(a, pour: L.t("Pour la désinstaller, il faut la fermer.", "It has to quit to be uninstalled.")) != nil else {
            return message ?? L.t("\(a.nom) n'est pas fermée", "\(a.nom) is still open")
        }
        let presente = FileManager.default.fileExists(atPath: a.chemin)   // un second clic ne note pas deux fois
        let echecs = await Desinstalleur.mettreALaCorbeille(chemins)
        if presente && !FileManager.default.fileExists(atPath: a.chemin) {
            // Homebrew garderait sinon l'app dans sa liste d'installées.
            if let k = a.cask, contexte.casksInstalles.contains(k.token) {
                _ = await Shell.lancer(Homebrew.chemin, ["uninstall", "--cask", "--force", k.token])
                contexte.casksInstalles.remove(k.token)
            }
            apps.removeAll { $0.chemin == a.chemin }
            var v = Historique.versionsVues()
            v[a.chemin] = nil
            Historique.enregistrer(versions: v)
            noter([.init(date: Date(), nom: a.nom, bundleId: a.bundleId, avant: a.versionAffichee, apres: nil, quoi: "Désinstallée", par: "Mises à jour")])
        }
        apps.removeAll { $0.chemin == a.chemin && !FileManager.default.fileExists(atPath: a.chemin) }
        return echecs.isEmpty ? nil : L.t("Restés en place : ", "Left in place: ") + echecs.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
    }

    // MARK: - Notification

    private func notifier() {
        let nouvelles = aMettreAJour.filter { !notifiees.contains("\($0.bundleId)@\($0.disponible ?? "")") }
        guard !nouvelles.isEmpty else { return }
        notifiees.formUnion(nouvelles.map { "\($0.bundleId)@\($0.disponible ?? "")" })
        reglages.set(Array(notifiees), forKey: "notifiees")
        guard notifications else { return }
        let titre = nouvelles.count == 1 ? L.t("1 mise à jour disponible", "1 update available") : L.t("\(nouvelles.count) mises à jour disponibles", "\(nouvelles.count) updates available")
        let corps = nouvelles.map(\.nom).joined(separator: ", ")
        let centre = UNUserNotificationCenter.current()
        centre.requestAuthorization(options: [.alert, .sound]) { ok, _ in
            guard ok else { return }
            let c = UNMutableNotificationContent()
            c.title = titre
            c.body = corps
            centre.add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
        }
    }
}
