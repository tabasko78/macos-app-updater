import AppKit
import ServiceManagement
import UserNotifications

@MainActor
final class Moteur: ObservableObject {
    @Published var apps: [AppInstallee] = []
    @Published var enCours = false
    @Published var derniereVerif: Date?
    /// Les messages affichés au-dessus de la liste, le plus récent en tête. Un lot de 20 mises à jour peut en
    /// produire plusieurs : ils s'empilent au lieu de se remplacer, et chacun se ferme d'un clic.
    @Published var avis: [Avis] = []
    struct Avis: Identifiable, Equatable {
        let id = UUID()
        let texte: String
    }

    /// Écrire un message l'ajoute en tête de la pile (sans doublon) ; nil ne fait rien.
    var message: String? {
        get { avis.first?.texte }
        set {
            guard let v = newValue, !v.isEmpty else { return }
            avis.removeAll { $0.texte == v }
            avis.insert(Avis(texte: v), at: 0)
            if avis.count > 50 { avis.removeLast(avis.count - 50) }
        }
    }

    func retirerAvis(_ a: Avis) { avis.removeAll { $0.id == a.id } }
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
    @Published var hauteurFenetre: CGFloat = 0           // hauteur naturelle du contenu de la fenêtre
    var journalOuvert = false                            // le Journal agrandit la fenêtre, sans jamais la réduire
    @Published var resumes: [String: String] = Resumeur.cache()   // bundle id@version → résumé Gemini
    @Published var nouvelleVersionApp: Regles.Publication?        // version plus récente de cette app sur GitHub
    @Published var majApp = false                                 // mise à jour de cette app en cours

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
    @Published var delai: Int { didSet { reglages.set(delai, forKey: "delai") } }             // jours avant de proposer une version
    @Published var automatique: Bool { didSet { reglages.set(automatique, forKey: "automatique") } }
    @Published var gemini: Bool { didSet { reglages.set(gemini, forKey: "gemini"); Task { await resumer() } } }
    private var premieresVues: [String: Date] = Historique.premieresVues()   // bundle id@version → vue la 1re fois

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
        delai = reglages.object(forKey: "delai") as? Int ?? 0
        automatique = reglages.bool(forKey: "automatique")
        gemini = reglages.bool(forKey: "gemini")
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

    /// Les mises à jour proposées : disponibles, non ignorées, et « éprouvées » si un délai est réglé.
    var aMettreAJour: [AppInstallee] { apps.filter { $0.aJour == false && $0.incompatible == nil && !estIgnoree($0) && joursRestants($0) == nil } }

    /// Mises à jour qui ne peuvent pas tourner sur ce Mac : affichées grisées avec la raison, ni comptées ni proposées.
    var incompatibles: [AppInstallee] { apps.filter { $0.aJour == false && $0.incompatible != nil && !estIgnoree($0) } }

    /// Les mises à jour trop récentes pour le délai choisi : affichées en attente, ni comptées ni proposées.
    var enAttente: [AppInstallee] { apps.filter { $0.aJour == false && $0.incompatible == nil && !estIgnoree($0) && joursRestants($0) != nil } }

    private func cle(_ a: AppInstallee) -> String { a.bundleId + "@" + (a.disponible ?? "") }

    /// Jours avant qu'une nouvelle version soit proposée, nil si elle l'est déjà. Elle compte depuis sa date de
    /// publication quand la source la donne, sinon depuis le jour où l'app l'a vue pour la première fois.
    func joursRestants(_ a: AppInstallee) -> Int? {
        guard delai > 0 else { return nil }
        let vue = premieresVues[cle(a)] ?? Date()
        let depuis = min(a.datePublication ?? vue, vue)
        let ecoules = Calendar.current.dateComponents([.day], from: depuis, to: Date()).day ?? 0
        let reste = delai - ecoules
        return reste > 0 ? reste : nil
    }

    /// « rien| » : Gemini n'a rien trouvé pour cette version, retenu pour ne plus le redemander, jamais affiché.
    func resume(_ a: AppInstallee) -> String? { resumes[cle(a)].flatMap { $0.hasPrefix("rien|") ? nil : $0 } }

    // MARK: - Vérification

    func verifier() async {
        guard !enCours else { return }
        enCours = true
        let r = await Verification.tout()
        contexte = r.contexte
        apps = r.apps.sorted { $0.nom.localizedCaseInsensitiveCompare($1.nom) == .orderedAscending }
        if !r.erreurs.isEmpty { message = r.erreurs.joined(separator: " · ") }
        derniereVerif = Date()
        let restantes = Set(cochables.map(\.id))
        selection = selection.intersection(restantes)
        enCours = false
        retenirPremieresVues()
        comparerAvecLaDerniereFois()
        notifier()
        mesurerTailles()
        await verifierApp()
        if automatique { await mettreAJourAutomatiquement() }
        await resumer()
    }

    private func retenirPremieresVues() {
        var nouvelles: [String: Date] = [:]
        for a in apps where a.aJour == false { nouvelles[cle(a)] = premieresVues[cle(a)] ?? Date() }
        premieresVues = nouvelles
        Historique.enregistrer(premieresVues: nouvelles)
    }

    // MARK: - Mises à jour automatiques

    /// Réglage « Mises à jour automatiques » : les apps proposées s'installent seules, sauf celles qui sont
    /// ouvertes, celles qui demanderaient le mot de passe (paquets, apps au nom du système) et les versions majeures.
    private func mettreAJourAutomatiquement() async {
        let candidates = aMettreAJour.filter { a in
            guard !a.majeure else { return false }
            switch a.action {
            case .brew(_, false), .installer: break
            default: return false
            }
            let ouverte = !NSRunningApplication.runningApplications(withBundleIdentifier: a.bundleId)
                .filter { $0.bundleURL?.path == a.chemin }.isEmpty
            let proprietaire = (try? FileManager.default.attributesOfItem(atPath: a.chemin))?[.ownerAccountName] as? String
            return !ouverte && proprietaire == NSUserName()
        }
        guard !candidates.isEmpty, lot == nil else { return }
        MotDePasse.partage.silencieux = true   // jamais de fenêtre de mot de passe sans quelqu'un devant
        defer { MotDePasse.partage.silencieux = false }
        let avant = Set(aMettreAJour.map(\.id))
        await enLot(candidates)
        let faites = candidates.filter { c in avant.contains(c.id) && !aMettreAJour.contains { $0.id == c.id } }
        guard !faites.isEmpty, notifications else { return }
        envoyerNotification(faites.count == 1 ? L.t("1 app mise à jour automatiquement", "1 app updated automatically")
                                              : L.t("\(faites.count) apps mises à jour automatiquement", "\(faites.count) apps updated automatically"),
                            faites.map(\.nom).joined(separator: ", "))
    }

    // MARK: - Résumés Gemini

    /// Résume les notes de version des mises à jour en vue, une seule fois par version.
    /// Une erreur Gemini n'est affichée que tant qu'elle est vraie : effacée au prochain essai, et dès qu'un résumé passe.
    private var messageGemini: String?

    func resumer() async {
        guard gemini, let k = Resumeur.cle else { return }
        if let g = messageGemini { avis.removeAll { $0.texte == g } }
        messageGemini = nil
        // Une version qui a échoué (Gemini saturé, réseau…) n'est retentée qu'une fois par jour : sinon chaque
        // vérification, toutes les heures, repayait l'appel (68 appels pour 33 résumés sur l'iMac, 29/10/2026).
        var echecs = reglages.dictionary(forKey: "echecsGemini") as? [String: Date] ?? [:]
        echecs = echecs.filter { -$0.value.timeIntervalSinceNow < 86_400 }
        defer { reglages.set(echecs, forKey: "echecsGemini") }
        for a in aMettreAJour + enAttente where resumes[cle(a)] == nil && echecs[cle(a)] == nil {
            let notes = await Resumeur.notes(a)
            do {
                if let notes {
                    resumes[cle(a)] = try await Resumeur.resumer(a, notes: notes, cle: k)
                } else {
                    // Pas de notes publiées (Homebrew) : Gemini cherche sur le web. « web| » marque l'origine.
                    do {
                        resumes[cle(a)] = "web|" + (try await Resumeur.resumerWeb(a, cle: k))
                    } catch let e as ErreurSource where e.errorDescription == "" {
                        resumes[cle(a)] = "rien|"   // rien trouvé de fiable : retenu, plus jamais redemandé
                    }
                }
                Resumeur.enregistrer(resumes)
                if let g = messageGemini { avis.removeAll { $0.texte == g } }
                messageGemini = nil
            } catch {
                echecs[cle(a)] = Date()
                messageGemini = error.localizedDescription
                message = messageGemini
                return
            }
        }
    }

    // MARK: - Mise à jour de cette app

    static let depotApp = "tabasko78/macos-app-updater"
    static var versionApp: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }
    /// Une copie perso (réglages propres, perso.json) ne se remplace pas par la version publique : elle signale seulement.
    static var copiePerso: Bool { ConfigApp.perso != nil }

    private func verifierApp() async {
        guard let p = try? await Regles.github(Self.depotApp), Versions.plusRecent(p.version, que: Self.versionApp) else {
            nouvelleVersionApp = nil
            return
        }
        nouvelleVersionApp = p
    }

    func mettreAJourApp() async {
        guard let p = nouvelleVersionApp else { return }
        guard !Self.copiePerso, let f = p.fichier else {
            if let u = p.url { NSWorkspace.shared.open(u) }
            return
        }
        majApp = true
        defer { majApp = false }
        do {
            let fichier = try await Installeur.telecharger(f) { _, _ in }
            defer { Installeur.nettoyer(fichier) }
            if let sha = p.sha256, try Installeur.empreinte(fichier) != sha.lowercased() {
                throw ErreurSource(L.t("empreinte du fichier incorrecte, téléchargement refusé", "wrong file hash, download rejected"))
            }
            let nouvelle = try await Installeur.extraire(fichier)
            let id = (NSDictionary(contentsOfFile: nouvelle.path + "/Contents/Info.plist") as? [String: Any])?["CFBundleIdentifier"] as? String
            guard id == Bundle.main.bundleIdentifier else { throw ErreurSource(L.t("le fichier téléchargé n'est pas cette app", "the downloaded file is not this app")) }
            let moi = Bundle.main.bundlePath
            try await Installeur.remplacer(moi, par: nouvelle)
            // Relance la nouvelle version une seconde après la fermeture de celle-ci.
            let relance = Process()
            relance.executableURL = URL(fileURLWithPath: "/bin/sh")
            relance.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", moi]
            try relance.run()
            NSApp.terminate(nil)
        } catch {
            message = L.t("Mise à jour de l'app impossible : ", "Could not update the app: ") + error.localizedDescription
        }
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

    /// Bouton « Effacer la liste » du Journal, après confirmation.
    func effacerJournal() {
        let alerte = NSAlert()
        alerte.messageText = L.t("Effacer tout le journal ?", "Clear the whole log?")
        alerte.informativeText = L.t("Les \(historique.count) lignes seront supprimées. Les apps et leurs versions ne sont pas touchées.",
                                     "The \(historique.count) lines will be deleted. Apps and their versions are not affected.")
        alerte.addButton(withTitle: L.t("Effacer", "Clear"))
        alerte.addButton(withTitle: L.t("Annuler", "Cancel"))
        guard alerte.runModal() == .alertFirstButtonReturn else { return }
        historique = []
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
        avis.removeAll()   // un nouveau lot repart d'une pile propre
        var echecs: [String] = []
        for a in liste {
            await mettreAJour(a)
            selection.remove(a.id)
            // Une app encore dans la liste après son passage n'a pas été mise à jour (Homebrew seulement :
            // App Store, page et Terminal ne font qu'ouvrir quelque chose).
            if case .brew = a.action, aMettreAJour.contains(where: { $0.id == a.id }) { echecs.append(a.nom) }
            if case .installer = a.action, aMettreAJour.contains(where: { $0.id == a.id }) { echecs.append(a.nom) }
            lot = (lot!.fait + 1, liste.count)
        }
        lot = nil
        // Bilan du lot, au lieu du message de la dernière app seulement.
        let faites = liste.count - echecs.count
        message = echecs.isEmpty
            ? L.t("\(faites) mise\(faites > 1 ? "s" : "") à jour terminée\(faites > 1 ? "s" : "")", "\(faites) update\(faites > 1 ? "s" : "") done")
            : L.t("\(faites) sur \(liste.count) terminées. Échecs : \(echecs.joined(separator: ", ")) (détail dans la sortie Homebrew).",
                  "\(faites) of \(liste.count) done. Failed: \(echecs.joined(separator: ", ")) (details in the Homebrew output).")
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
        guard Homebrew.present else { message = L.t("Homebrew est introuvable (ni /opt/homebrew, ni /usr/local)", "Homebrew was not found (neither /opt/homebrew nor /usr/local)"); return }
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
        await viderCacheSiAdresseFixe(a.cask)
        // Lancé dans un terminal simulé (script) : sans lui, Homebrew garde tout ce qu'il écrit
        // jusqu'à la fin, et les étapes n'arrivent qu'une fois l'installation terminée.
        // HOMEBREW_AUTO_UPDATE_SECS : Homebrew rafraîchit son catalogue s'il a plus de 5 min. Par défaut il attend
        // 24 h, et réinstallait alors l'ancienne version (Signal 8.32.0 « mis à jour » en 8.32.0 le 29/10/2026).
        let r = await Shell.lancer("/usr/bin/script", ["-q", "/dev/null", Homebrew.chemin] + args,
                                   env: ["HOMEBREW_AUTO_UPDATE_SECS": "300", "SUDO_ASKPASS": MotDePasse.partage.askpass()]) { morceau in
            Task { @MainActor [weak self] in self?.lireSortie(morceau, id) }
        }
        Self.consigner("brew " + args.joined(separator: " "), r.code, r.sortie)
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
            if r.sortie.contains("incorrect password") || r.sortie.contains("Sorry, try again") || r.sortie.contains("no password was provided") {
                MotDePasse.partage.oublier()
            }
            message = L.t("Échec de la mise à jour de \(a.nom), le détail est dans la sortie Homebrew", "Updating \(a.nom) failed, see the Homebrew output")
            // Homebrew vieillissant ou installé par un autre compte du Mac (iMac de 2017, 29/10/2026).
            if r.sortie.contains("shallow clone") {
                message = L.t("Le Homebrew de ce Mac ne peut plus se mettre à jour : lance « brew untap homebrew/core » puis « brew update » dans le Terminal.",
                              "This Mac's Homebrew can no longer update: run “brew untap homebrew/core” then “brew update” in Terminal.")
            } else if r.sortie.contains("Permission denied") {
                message = L.t("Homebrew appartient à un autre compte de ce Mac : il faut lui rendre la main (« sudo chown -R $(whoami) $(brew --prefix)/* » dans le Terminal).",
                              "Homebrew belongs to another account on this Mac: take it back (“sudo chown -R $(whoami) $(brew --prefix)/*” in Terminal).")
            }
            // macOS interdit de modifier une app sans l'autorisation « Gestion des apps » (Chrome, 29/10/2026).
            if r.sortie.contains("Operation not permitted") {
                message = L.t("macOS a bloqué le remplacement de \(a.nom) : coche « macOS App Updater » dans Réglages Système > Confidentialité et sécurité > Gestion des apps, puis recommence.",
                              "macOS blocked replacing \(a.nom): enable “macOS App Updater” in System Settings > Privacy & Security > App Management, then try again.")
            }
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

    /// Certains casks téléchargent toujours la même adresse (Chrome : …/stable/googlechrome.dmg), sans numéro de
    /// version ni empreinte. Homebrew réutilisait alors le fichier gardé en cache, donc l'ANCIENNE version
    /// (Chrome 156.0.8078.73 au lieu de .74, 29/10/2026) : on l'efface avant, pour forcer un vrai téléchargement.
    private func viderCacheSiAdresseFixe(_ k: CaskInfo?) async {
        guard let k, let url = k.url, let v = k.version, !url.contains(v) else { return }
        let r = await Shell.lancer(Homebrew.chemin, ["--cache", "--cask", k.token], env: ["HOMEBREW_NO_AUTO_UPDATE": "1"])
        let chemin = r.sortie.trimmingCharacters(in: .whitespacesAndNewlines)
        if r.code == 0, chemin.hasPrefix("/"), FileManager.default.fileExists(atPath: chemin) {
            try? FileManager.default.removeItem(atPath: chemin)
            sortieBrew += L.t("ancien fichier en cache effacé : ", "old cached file removed: ") + (chemin as NSString).lastPathComponent + "\n"
        }
    }

    /// Chaque passage de Homebrew est gardé dans homebrew.log (dossier de l'app), pour comprendre un échec après coup.
    nonisolated static func consigner(_ commande: String, _ code: Int32, _ sortie: String) {
        let f = Dossiers.support.appendingPathComponent("homebrew.log")
        let propre = sortie.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\r", with: "\n")
        let bloc = "\n=== \(Date().formatted(.iso8601)) · \(commande) · code \(code)\n\(propre)\n"
        var ancien = (try? String(contentsOf: f, encoding: .utf8)) ?? ""
        if ancien.count > 400_000 { ancien = String(ancien.suffix(200_000)) }
        try? (ancien + bloc).write(to: f, atomically: true, encoding: .utf8)
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


    /// Les paquets .pkg demandent le mot de passe administrateur : seul un vrai Terminal peut le recevoir.
    private func ouvrirDansTerminal(_ a: AppInstallee, token: String) {
        let script = """
        #!/bin/zsh
        echo L.t("Mise à jour de \(a.nom) par Homebrew. Le mot de passe demandé est celui de ta session.", "Updating \(a.nom) with Homebrew. The password asked for is your login password.")
        echo
        HOMEBREW_AUTO_UPDATE_SECS=300 \(Homebrew.chemin) install --cask --force \(token)
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
        envoyerNotification(titre, nouvelles.map(\.nom).joined(separator: ", "))
    }

    private func envoyerNotification(_ titre: String, _ corps: String) {
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
