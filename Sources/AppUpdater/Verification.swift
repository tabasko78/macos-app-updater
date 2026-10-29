import Foundation

/// Tout ce que les sources ont répondu lors de la dernière vérification, pour pouvoir réévaluer une app seule.
struct Contexte: Sendable {
    var index: Homebrew.Index?
    var mas: [String: AppStore.Fiche] = [:]
    var sparkle: [String: Sparkle.Element] = [:]      // par chemin de l'app
    var sparkleEnPanne: Set<String> = []
    var publications: [String: Regles.Publication] = [:]   // par bundle id
    var reglesEnPanne: Set<String> = []
    var casksInstalles: Set<String> = []
    var versionsBrew: [String: String] = [:]     // cask → version que Homebrew a installée
    var ids: [String: String] = [:]              // bundle id → nom, des apps suivies par une vraie source
    var classements: [String: String] = [:]      // bundle id → Classement choisi à la main (clic droit)
}

enum Verification {
    static func tout() async -> (apps: [AppInstallee], contexte: Contexte, erreurs: [String]) {
        let liste = Inventaire.scanner()
        var ctx = Contexte()
        var erreurs: [String] = []
        let regles = Regles.toutes()
        ctx.classements = UserDefaults.standard.dictionary(forKey: "classements") as? [String: String] ?? [:]

        async let index = Result { try await Homebrew.charger() }
        async let installes = Homebrew.installes()
        async let mas = Result { try await AppStore.verifier(liste.filter(\.mas).map(\.bundleId)) }
        async let sparkle = Sparkle.verifierTous(liste.filter { !$0.mas }.compactMap { a in a.feedSparkle.map { (a.chemin, $0) } })

        switch await index {
        case .success(let i): ctx.index = i
        case .failure(let e): erreurs.append(L.t("Homebrew : \(e.localizedDescription)", "Homebrew: \(e.localizedDescription)"))
        }
        // Règles écrites (intégrées ou du fichier) : toujours. Fichier Electron de l'app : seulement si ni Homebrew
        // ni Sparkle ne la suivent, ou si Homebrew l'a retirée (Signal en a un, mais Homebrew sait l'installer, lui).
        for a in liste where !a.mas {
            let electron = a.feedSparkle == nil && (ctx.index?.trouver(a)?.retire ?? true) ? Regles.depuisElectron(a) : nil
            guard let r = regles[a.bundleId] ?? electron else { continue }
            if let p = try? await Regles.verifier(r) { ctx.publications[a.bundleId] = p } else { ctx.reglesEnPanne.insert(a.bundleId) }
        }
        switch await mas {
        case .success(let m): ctx.mas = m
        case .failure(let e): erreurs.append(L.t("App Store : \(e.localizedDescription)", "App Store: \(e.localizedDescription)"))
        }
        for (chemin, r) in await sparkle {
            switch r {
            case .success(let e?): ctx.sparkle[chemin] = e
            case .success(nil): break
            case .failure: ctx.sparkleEnPanne.insert(chemin)
            }
        }
        ctx.versionsBrew = await installes
        ctx.casksInstalles = Set(ctx.versionsBrew.keys)
        // Deux passes : une app n'est le composant d'une autre que si cette autre est réellement suivie
        // (RealTimeSync avec FreeFileSync), pas entre deux apps sans source du même éditeur.
        let suivies = liste.map { resoudre($0, ctx) }.filter { [.homebrew, .sparkle, .appStore, .editeur, .github].contains($0.source) }
        ctx.ids = Dictionary(suivies.map { ($0.bundleId, $0.nom) }, uniquingKeysWith: { a, _ in a })
        return (liste.map { resoudre($0, ctx) }, ctx, erreurs)
    }

    /// Homebrew installe sous le nom prévu par le cask : si l'app porte un autre nom (CleanMyMac_5.app
    /// contre CleanMyMac.app), il poserait une seconde copie à côté au lieu de remplacer la première.
    static func brewRemplace(_ a: AppInstallee, _ k: CaskInfo) -> Bool {
        let nom = (a.chemin as NSString).lastPathComponent.lowercased()
        return !k.retire && (k.apps.isEmpty || k.apps.contains { $0.lowercased() == nom })
    }

    static func resoudre(_ app: AppInstallee, _ c: Contexte) -> AppInstallee {
        var a = resoudreBrut(app.brute, c)
        // Classement choisi à la main, sinon déduit pour une app dont on ne connaît pas la version disponible.
        if let choix = c.classements[a.bundleId].flatMap(Classement.init(rawValue:)) {
            a.source = choix.source
            a.aJour = nil
            a.action = .aucune
            a.remarque = L.t("classée à la main : ", "classified by hand: ") + choix.explication
            return a
        }
        if a.aJour == nil, let (classe, raison) = Classeur.classer(a, ids: c.ids) {
            a.source = classe.source
            a.remarque = raison
            return a
        }
        // Un saut de version majeure (Parallels 26 → 27) peut demander une nouvelle licence payante.
        if a.aJour == false, let d = a.disponible,
           let x = Versions.morceaux(a.versionAffichee).first.flatMap({ Int($0) }),
           let y = Versions.morceaux(d).first.flatMap({ Int($0) }), y > x, x < 50 {   // les navigateurs (Firefox 158) changent de majeure chaque mois
            a.majeure = true
            if a.remarque == nil { a.remarque = L.t("nouvelle version majeure, la licence peut être payante", "new major version, the license may be paid") }
        }
        return a
    }

    private static func resoudreBrut(_ app: AppInstallee, _ c: Contexte) -> AppInstallee {
        var a = app
        a.cask = c.index?.trouver(a)

        if a.mas {
            a.source = .appStore
            if let f = c.mas[a.bundleId.lowercased()] {
                a.disponible = f.version
                a.datePublication = f.date
                a.notes = f.notes
                a.aJour = !Versions.plusRecent(f.version, que: a.versionAffichee)
                a.action = f.url.map { .appStore($0) } ?? .aucune
            } else {
                a.remarque = L.t("introuvable sur l'App Store (retirée de la vente ?)", "not found on the App Store (withdrawn?)")
            }
            return a
        }

        if let p = c.publications[a.bundleId] {
            a.source = p.source
            a.disponible = p.version
            a.datePublication = p.date
            a.notes = p.notes
            a.aJour = !Versions.plusRecent(p.version, que: a.versionAffichee)
            if let f = p.fichier {
                a.action = .installer(f, sha256: p.sha256)
            } else {
                a.action = p.url.map { p.source == .github ? .page($0) : .telecharger($0) } ?? .aucune
            }
            return a
        }

        // Sparkle d'abord pour savoir : c'est l'éditeur lui-même qui annonce sa version.
        if let e = c.sparkle[a.chemin] {
            a.source = .sparkle
            let dispo = e.court ?? e.build!
            a.disponible = dispo
            a.datePublication = e.date
            a.notes = e.notes
            a.notesLien = e.notesLien
            if let b = e.build {
                // sparkle:version se compare à CFBundleVersion, comme le fait Sparkle
                a.aJour = !Versions.plusRecent(b, que: a.build.isEmpty ? a.version : a.build)
            } else {
                a.aJour = !Versions.plusRecent(dispo, que: a.versionAffichee)
            }
            // Homebrew pour installer, seulement s'il a déjà la version annoncée.
            if let k = a.cask, let v = k.version, !Versions.plusRecent(dispo, que: v), brewRemplace(a, k) {
                a.action = .brew(token: k.token, terminal: k.terminal)
            } else if let f = Regles.installable(e.url) {
                a.action = .installer(f, sha256: nil)
            } else if let u = e.url {
                a.action = .telecharger(u)
            } else {
                a.action = .ouvrirApp
            }
            return a
        }

        if let k = a.cask {
            a.source = .homebrew
            guard let v = k.version else {
                a.remarque = L.t("Homebrew ne publie pas de numéro de version pour cette app", "Homebrew publishes no version number for this app")
                return a
            }
            a.disponible = v
            // Homebrew sait ce qu'il a installé : iStat Menus 7.50.1 s'affiche « 7.50 » dans son Info.plist.
            a.aJour = !Versions.plusRecent(v, que: a.versionAffichee)
                || (!a.build.isEmpty && Versions.comparer(v, a.build) == .orderedSame)
                || c.versionsBrew[k.token] == v
            if k.retire {
                a.action = .aucune
                a.remarque = L.t("n'est plus maintenue : retirée de Homebrew, dernière version publiée \(v)", "no longer maintained: removed from Homebrew, last version \(v)")
            } else if brewRemplace(a, k) {
                a.action = .brew(token: k.token, terminal: k.terminal)
            } else {
                a.action = .ouvrirApp
                a.remarque = L.t("Homebrew l'installerait sous le nom \(k.apps[0]), à mettre à jour depuis l'app elle-même", "Homebrew would install it as \(k.apps[0]); update it from the app itself")
            }
            if c.sparkleEnPanne.contains(a.chemin) { a.remarque = L.t("flux Sparkle injoignable, version lue chez Homebrew", "Sparkle feed unreachable, version taken from Homebrew") }
            return a
        }

        a.source = .aucune
        if c.sparkleEnPanne.contains(a.chemin) { a.remarque = L.t("flux Sparkle injoignable", "Sparkle feed unreachable") }
        if c.reglesEnPanne.contains(a.bundleId) { a.remarque = L.t("la source de l'éditeur ne répond plus, règle à revoir", "the developer's source no longer answers, rule to review") }
        return a
    }
}

extension Result where Failure == Error {
    init(catching f: () async throws -> Success) async {
        do { self = .success(try await f()) } catch { self = .failure(error) }
    }
}
