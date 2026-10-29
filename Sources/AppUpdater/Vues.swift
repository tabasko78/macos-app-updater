import SwiftUI
import UniformTypeIdentifiers

// Les outils en ligne de commande (sans Xcode) n'ont pas le greffon de la macro @State :
// l'état local des vues passe par de petits objets observés.

// MARK: - Icônes, mises en cache : NSWorkspace est lent

@MainActor
enum Icones {
    private static var cache: [String: NSImage] = [:]
    static func icone(_ chemin: String) -> NSImage {
        if let i = cache[chemin] { return i }
        let i = NSWorkspace.shared.icon(forFile: chemin)
        cache[chemin] = i
        return i
    }
}

// MARK: - Une ligne d'application : clic gauche ouvre l'app, clic droit le menu

struct LigneApp: View {
    @EnvironmentObject var m: Moteur
    let app: AppInstallee
    var compacte = false

    private var largeurBouton: CGFloat { compacte ? 116 : 132 }

    /// Taille sur le disque, collée au nom.
    private var details: String? { m.tailles[app.chemin].map(Desinstalleur.lisible) }

    /// Colonne « Utilisée il y a 3 jours » / « Jamais utilisée », d'après Spotlight.
    private var usage: String {
        guard let u = app.derniereUtilisation else { return L.t("Jamais utilisée", "Never used") }
        let f = RelativeDateTimeFormatter()
        f.locale = L.locale
        f.unitsStyle = .full
        return L.t("Utilisée ", "Used ") + f.localizedString(for: u, relativeTo: Date())
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                if !compacte {
                    if app.aJour == false && app.action != .aucune && !m.estIgnoree(app) && m.joursRestants(app) == nil {
                        CaseACocher(cochee: m.selection.contains(app.id)) { m.basculer(app) }
                    } else {
                        Color.clear.frame(width: 18, height: 18)
                    }
                }
                Image(nsImage: Icones.icone(app.chemin)).resizable().frame(width: compacte ? 24 : 30, height: compacte ? 24 : 30)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(app.nom).font(T.police(compacte ? 12 : 13, .semibold)).foregroundStyle(T.texte).lineLimit(1)
                        if let d = details { Text("(\(d))").font(T.police(compacte ? 10 : 11)).foregroundStyle(T.tresDoux).fixedSize() }
                    }
                    if !compacte, let r = app.remarque {
                        Text(r).font(T.police(10)).foregroundStyle(T.tresDoux).lineLimit(1)
                    }
                    if !compacte, let r = m.resume(app) {
                        let web = r.hasPrefix("web|")
                        (Text(web ? String(r.dropFirst(4)) : r)
                            + Text(web ? L.t("  · d'après le web", "  · from the web") : "").foregroundStyle(T.tresDoux))
                            .font(T.police(11)).foregroundStyle(T.doux).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                if !compacte {
                    Text(usage).font(T.police(11)).foregroundStyle(T.tresDoux).lineLimit(1)
                        .frame(width: 170, alignment: .leading)
                }
                versions
                if !compacte { pastille }
                bouton
            }
            if let p = m.progression[app.id] { barre(p) }
        }
        .padding(.horizontal, 10).padding(.vertical, compacte ? 5 : 7)
        .padding(.bottom, m.progression[app.id] != nil ? 4 : 0)
        .verre(10)
        // Carte en cours de mise à jour : liseré de la couleur du thème, pour la distinguer des autres.
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(T.accent.opacity(m.progression[app.id] != nil ? 0.55 : 0), lineWidth: 1))
        .opacity(m.estIgnoree(app) ? 0.55 : 1)
        .contextMenu { menu }
    }

    /// Bloc de progression posé dans un encart de la carte, pour qu'il ne se confonde pas avec l'espace entre deux cartes.
    private func barre(_ p: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(m.etape[app.id] ?? "").font(T.police(11, .medium)).foregroundStyle(T.texte.opacity(0.85)).lineLimit(1)
                Spacer()
                Text("\(Int(min(1, max(0, p)) * 100)) %").font(T.police(11, .semibold)).foregroundStyle(T.texte).monospacedDigit()
            }
            BarreProgression(valeur: p)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(Color.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(T.accent.opacity(0.22), lineWidth: 1))
        .padding(.leading, compacte ? 0 : 28)   // aligné sous l'icône, pas sous la case à cocher
    }

    private var versions: some View {
        HStack(spacing: 4) {
            Text(app.versionAffichee).foregroundStyle(T.versionActuelle)
            if app.aJour == false, let d = app.disponible {
                Image(systemName: "arrow.right").font(.system(size: 9, weight: .bold)).foregroundStyle(T.tresDoux)
                Text(d).foregroundStyle(T.versionNouvelle)
            }
        }
        .font(T.police(compacte ? 11 : 12, .medium))
        .lineLimit(1)
    }

    private var pastille: some View {
        Text(app.source.libelle)
            .font(T.police(10, .semibold))
            .foregroundStyle(T.couleur(app.source))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(T.couleur(app.source).opacity(0.12), in: Capsule())
            .frame(width: 104, alignment: .trailing)
    }

    @ViewBuilder private var bouton: some View {
        if app.aJour == false, let j = m.joursRestants(app) {
            Text(L.t("éprouvée dans \(j) j", "proven in \(j) d")).font(T.police(11)).foregroundStyle(T.tresDoux)
                .help(L.t("Réglages > Délai avant de proposer une version", "Settings > Delay before offering a version"))
                .frame(width: largeurBouton, alignment: .trailing)
        } else if m.progression[app.id] != nil {
            Text(L.t("en cours", "updating")).font(T.police(11)).foregroundStyle(T.doux).frame(width: largeurBouton, alignment: .trailing)
        } else if app.aJour == false, app.action != .aucune {
            Button(libelle) { Task { await m.mettreAJour(app) } }
                .buttonStyle(BoutonPlein(teinte: Boutons.teinte(app.action)))
                .help(aide)
                .frame(width: largeurBouton, alignment: .trailing)
        } else if app.aJour == true {
            Image(systemName: "checkmark").foregroundStyle(T.accent.opacity(0.7)).frame(width: largeurBouton, alignment: .trailing)
        } else {
            Text("–").foregroundStyle(T.tresDoux).frame(width: largeurBouton, alignment: .trailing)
        }
    }

    private var libelle: String {
        switch app.action {
        case .brew: L.t("Mettre à jour", "Update")
        case .installer: L.t("Mettre à jour", "Update")
        case .appStore: "App Store"
        case .telecharger: L.t("Télécharger", "Download")
        case .ouvrirApp: L.t("Ouvrir", "Open")
        case .page: L.t("Voir la page", "View page")
        case .aucune: ""
        }
    }

    private var aide: String {
        switch app.action {
        case .brew(let t, let terminal):
            terminal ? L.t("Installe la nouvelle version par Homebrew (brew \(t)) ; ton mot de passe sera demandé", "Installs the new version with Homebrew (brew \(t)); your password will be asked for")
                     : L.t("Installe la nouvelle version par Homebrew (brew \(t)), l'app est fermée puis rouverte", "Installs the new version with Homebrew (brew \(t)); the app is quit and reopened")
        case .installer(let u, let sha):
            L.t("Télécharge \(u.lastPathComponent)\(sha != nil ? ", vérifie son empreinte" : ""), contrôle la signature de l'éditeur, puis remplace l'app (l'ancienne part à la Corbeille)", "Downloads \(u.lastPathComponent)\(sha != nil ? ", checks its hash" : ""), checks the developer signature, then replaces the app (the old one goes to the Trash)")
        case .appStore: L.t("Ouvre la fiche dans l'App Store", "Opens the App Store page")
        case .telecharger: L.t("Télécharge la nouvelle version annoncée par l'éditeur", "Downloads the new version announced by the developer")
        case .ouvrirApp: L.t("Ouvre l'app, qui proposera sa mise à jour", "Opens the app, which will offer its own update")
        case .page: L.t("Ouvre la page de l'éditeur", "Opens the developer's page")
        case .aucune: ""
        }
    }

    @ViewBuilder private var menu: some View {
        if app.aJour == false, app.disponible != nil, !m.estIgnoree(app) {
            Button(L.t("Ignorer la version \(app.disponible!)", "Ignore version \(app.disponible!)")) { m.ignorer(app) }
        }
        if m.estIgnoree(app) {
            Button(L.t("Suivre à nouveau", "Track again")) { m.neplusIgnorer(app) }
        } else {
            Button(L.t("Ne plus suivre cette app", "Stop tracking this app")) { m.nePlusSuivre(app) }
        }
        Divider()
        Button(L.t("Ouvrir", "Open")) { m.ouvrir(app) }
        Button(L.t("Afficher dans le Finder", "Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: app.chemin)]) }
        if let k = app.cask {
            Button(L.t("Copier « brew \(k.token) »", "Copy “brew \(k.token)”")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("brew install --cask --force \(k.token)", forType: .string)
            }
        }
        Menu(L.t("Classer comme", "Classify as")) {
            ForEach(Classement.allCases) { c in
                Button(c.libelle + " : " + c.explication) { m.classer(app, c) }
            }
            Divider()
            Button(L.t("Automatique", "Automatic")) { m.classer(app, nil) }
        }
        Divider()
        Button(L.t("Désinstaller…", "Uninstall…")) {
            m.aDesinstaller = app
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

// MARK: - Fenêtre principale

enum Onglet: String, CaseIterable, Identifiable {
    case applications = "Applications"
    case journal = "Journal"
    case reglages = "Réglages"
    var id: String { rawValue }
    var libelle: String {
        switch self {
        case .applications: L.t("Applications", "Apps")
        case .journal: L.t("Journal", "Log")
        case .reglages: L.t("Réglages", "Settings")
        }
    }
}

enum Filtre: String, CaseIterable, Identifiable {
    case aMettreAJour = "À mettre à jour"
    case toutes = "Toutes"
    case sansSource = "Sans source"
    case ignorees = "Ignorées"
    var id: String { rawValue }
    var libelle: String {
        switch self {
        case .aMettreAJour: L.t("À mettre à jour", "To update")
        case .toutes: L.t("Toutes", "All")
        case .sansSource: L.t("Sans source", "No source")
        case .ignorees: L.t("Ignorées", "Ignored")
        }
    }
}

enum Tri: CaseIterable, Identifiable {
    case nom, taille, usage
    var id: Self { self }
    var libelle: String {
        switch self {
        case .nom: L.t("Nom", "Name")
        case .taille: L.t("Taille", "Size")
        case .usage: L.t("Dernière utilisation", "Last used")
        }
    }
}

final class EtatFenetre: ObservableObject {
    @Published var onglet: Onglet = CommandLine.arguments.contains("--reglages") ? .reglages : .applications   // --reglages : pour vérifier la page
    @Published var filtre: Filtre = .aMettreAJour
    @Published var recherche = ""
    @Published var sortieOuverte = false
    @Published var survolDepot = false
    @Published var tri: Tri = .nom
    @Published var source: Source? = nil   // nil : toutes les sources
}

struct FenetreListe: View {
    @EnvironmentObject var m: Moteur
    @StateObject private var etat = EtatFenetre()

    var body: some View {
        ZStack {
            FondTheme()
            VStack(alignment: .leading, spacing: 14) {
                entete.padding(.bottom, 15)
                if let p = m.nouvelleVersionApp { bandeauApp(p) }
                switch etat.onglet {
                case .applications: applications
                case .journal: JournalVue()
                case .reglages: ReglagesVue()
                }
            }
            .padding([.horizontal, .bottom], 20)
            .padding(.top, 2)   // la barre de titre transparente laisse déjà sa hauteur au-dessus
            // Hauteur naturelle du contenu : le Delegue y ajuste la fenêtre.
            .background(GeometryReader { g in Color.clear.preference(key: HauteurCle.self, value: g.size.height) })
            .onPreferenceChange(HauteurCle.self) { h in m.hauteurFenetre = h }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            if etat.survolDepot {
                RoundedRectangle(cornerRadius: 16).stroke(T.rose, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .padding(8)
                    .overlay(Text(L.t("Dépose une app ici pour la désinstaller", "Drop an app here to uninstall it")).font(T.police(16, .semibold)).foregroundStyle(T.rose))
            }
        }
        .frame(minWidth: 820, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .preferredColorScheme(.dark)
        .id("\(m.theme.rawValue)-\(m.langue.rawValue)")

        // Glisser une app sur la fenêtre la propose à la désinstallation, comme AppCleaner.
        .onDrop(of: [.fileURL], isTargeted: $etat.survolDepot) { fournisseurs in
            guard let f = fournisseurs.first else { return false }
            _ = f.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.pathExtension == "app" else { return }
                Task { @MainActor in m.preparerDesinstallation(chemin: url.path) }
            }
            return true
        }
        .onChange(of: etat.onglet, initial: true) { _, o in m.journalOuvert = o == .journal }
        .sheet(item: $m.aDesinstaller) { DesinstallationVue(app: $0).environmentObject(m) }
    }

    /// Une version plus récente de cette app est sortie sur GitHub.
    private func bandeauApp(_ p: Regles.Publication) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles").foregroundStyle(T.accent)
            Text(L.t("Nouvelle version de l'app : \(p.version) (tu as \(Moteur.versionApp))", "New version of the app: \(p.version) (you have \(Moteur.versionApp))"))
                .font(T.police(12, .semibold)).foregroundStyle(T.texte)
            Spacer()
            if m.majApp {
                ProgressView().controlSize(.small)
            } else if Moteur.copiePerso || p.fichier == nil {
                Button(L.t("Voir sur GitHub", "View on GitHub")) { Task { await m.mettreAJourApp() } }.buttonStyle(BoutonDiscret())
            } else {
                Button(L.t("Mettre à jour l'app", "Update the app")) { Task { await m.mettreAJourApp() } }
                    .buttonStyle(BoutonPlein(teinte: Boutons.mettreAJour))
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .verre(10)
    }

    private var entete: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(L.t("Mises à jour", "App Updater"))
                .font(T.police(24, .bold))
                // Graphite : titre uni, sans dégradé ni couleur.
                .foregroundStyle(T.nom == .graphite
                                 ? AnyShapeStyle(T.texte)
                                 : AnyShapeStyle(LinearGradient(colors: [T.accent, T.rose], startPoint: .leading, endPoint: .trailing)))
                .fixedSize()
            // Juste à droite du titre : vérifier, et l'heure de la dernière vérification.
            Button { Task { await m.verifier() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(BoutonDiscret()).disabled(m.enCours).help(L.t("Vérifier maintenant", "Check now"))
            if m.enCours {
                ProgressView().controlSize(.small)
                Text(L.t("vérification…", "checking…")).font(T.police(11)).foregroundStyle(T.doux).fixedSize()
            } else if let d = m.derniereVerif {
                Text(L.t("vérifié à \(d.formatted(date: .omitted, time: .shortened))", "checked at \(d.formatted(date: .omitted, time: .shortened))")).font(T.police(11)).foregroundStyle(T.doux).fixedSize()
            }
            Spacer(minLength: 8)
            if let l = m.lot {
                Text(L.t("Lot : \(l.fait) / \(l.total)", "Batch: \(l.fait) / \(l.total)")).font(T.police(11, .semibold)).foregroundStyle(T.statut).fixedSize()
            }
            // Les onglets, complètement à droite.
            HStack(spacing: 6) {
                ForEach(Onglet.allCases) { o in
                    Button(o.libelle) { etat.onglet = o }.buttonStyle(Puce(active: etat.onglet == o))
                }
            }
        }
    }

    private func appsDuFiltre(_ f: Filtre) -> [AppInstallee] {
        switch f {
        case .aMettreAJour: m.aMettreAJour + m.enAttente
        case .toutes: m.apps
        case .sansSource: m.apps.filter { $0.source == .aucune && !m.estIgnoree($0) }
        case .ignorees: m.apps.filter { m.estIgnoree($0) }
        }
    }

    /// Les sources présentes dans le filtre en cours, dans un ordre fixe.
    private var sourcesPresentes: [Source] {
        let ordre: [Source] = [.homebrew, .sparkle, .appStore, .editeur, .github, .composant, .integree, .abandonnee, .perso, .aucune]
        let la = Set(appsDuFiltre(etat.filtre).map(\.source))
        return ordre.filter { la.contains($0) }
    }

    private var liste: [AppInstallee] {
        var base = appsDuFiltre(etat.filtre)
        if etat.filtre == .toutes, let src = etat.source { base = base.filter { $0.source == src } }
        if !etat.recherche.isEmpty { base = base.filter { $0.nom.localizedCaseInsensitiveContains(etat.recherche) } }
        if etat.filtre == .toutes {
            switch etat.tri {
            case .nom: break
            case .taille: base.sort { (m.tailles[$0.chemin] ?? -1) > (m.tailles[$1.chemin] ?? -1) }   // la plus lourde en tête
            case .usage:   // la moins utilisée en tête : jamais utilisée, puis la plus ancienne
                base.sort { ($0.derniereUtilisation ?? .distantPast) < ($1.derniereUtilisation ?? .distantPast) }
            }
        }
        return base
    }

    @ViewBuilder private var applications: some View {
        if let msg = m.message {
            Text(msg).font(T.police(11)).foregroundStyle(T.ambre).lineLimit(2)
        }
        HStack(spacing: 6) {
            ForEach(Filtre.allCases) { f in
                Button("\(f.libelle) (\(f == .aMettreAJour ? m.aMettreAJour.count : appsDuFiltre(f).count))") { etat.filtre = f }.buttonStyle(Puce(active: etat.filtre == f))
            }
            Spacer(minLength: 12)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(T.tresDoux)
                TextField(L.t("Rechercher", "Search"), text: $etat.recherche).textFieldStyle(.plain).font(T.police(12)).foregroundStyle(T.texte)
            }
            .padding(.horizontal, 10).padding(.vertical, 6).verre(14)
            .frame(minWidth: 130, maxWidth: 220)
            if !m.selection.isEmpty {
                Button(L.t("Mettre à jour la sélection (\(m.selection.count))", "Update selection (\(m.selection.count))")) { Task { await m.mettreAJourSelection() } }
                    .buttonStyle(BoutonPlein(teinte: Boutons.mettreAJour)).fixedSize().disabled(m.lot != nil)
                    .help(L.t("Seulement les apps cochées, l'une après l'autre", "Only the checked apps, one after the other"))
            } else if !m.cochables.isEmpty {
                Button(L.t("Tout mettre à jour (\(m.cochables.count))", "Update all (\(m.cochables.count))")) { Task { await m.toutMettreAJour() } }
                    .buttonStyle(BoutonPlein(teinte: Boutons.mettreAJour)).fixedSize().disabled(m.lot != nil)
                    .help(L.t("Toutes les apps à mettre à jour, l'une après l'autre : Homebrew installe, les autres ouvrent leur App Store, leur page ou le Terminal", "Every app to update, one after the other: Homebrew installs, the others open their App Store page, web page or Terminal"))
            }
        }
        // Le filtre par source ne sert que dans « Toutes », et seulement s'il y a plusieurs sources à départager.
        if etat.filtre == .toutes && sourcesPresentes.count > 1 {
        ScrollView(.horizontal, showsIndicators: false) { HStack(spacing: 6) {
            Text(L.t("Source", "Source")).font(T.police(12)).foregroundStyle(T.tresDoux)
            Button(L.t("Toutes", "All")) { etat.source = nil }.buttonStyle(Puce(active: etat.source == nil))
            ForEach(sourcesPresentes, id: \.self) { src in
                Button("\(src.libelle) (\(appsDuFiltre(etat.filtre).filter { $0.source == src }.count))") {
                    etat.source = etat.source == src ? nil : src
                }
                .buttonStyle(Puce(active: etat.source == src))
            }
        }.padding(.vertical, 6).padding(.horizontal, 2) }
        }
        if etat.filtre == .toutes {
            HStack(spacing: 6) {
                Text(L.t("Trier par", "Sort by")).font(T.police(12)).foregroundStyle(T.tresDoux)
                ForEach(Tri.allCases) { t in
                    Button(t.libelle) { etat.tri = t }.buttonStyle(Puce(active: etat.tri == t))
                }
                if etat.tri == .taille {
                    let total = m.tailles.values.reduce(0, +)
                    Text(L.t("· \(Desinstalleur.lisible(total)) au total", "· \(Desinstalleur.lisible(total)) in total")).font(T.police(12)).foregroundStyle(T.tresDoux)
                }
            }
        }
        if !m.cochables.isEmpty && (etat.filtre == .aMettreAJour || etat.filtre == .toutes) {
            let n = m.selection.count, total = m.cochables.count
            HStack(spacing: 10) {
                CaseACocher(cochee: n == total, partielle: n > 0 && n < total) { m.toutCocher(n < total) }
                Text(n == 0 ? L.t("Tout cocher", "Check all") : L.t("\(n) cochée\(n > 1 ? "s" : "") sur \(total)", "\(n) of \(total) checked"))
                    .font(T.police(12, .medium)).foregroundStyle(T.doux)
                    .onTapGesture { m.toutCocher(n < total) }
            }
            .padding(.horizontal, 10)
        }
        ListeAjustee(lignes: liste.count) {
            VStack(spacing: 6) {
                ForEach(liste) { LigneApp(app: $0) }
                if liste.isEmpty && !m.enCours {
                    Text(etat.filtre == .aMettreAJour ? L.t("Tout est à jour.", "Everything is up to date.") : L.t("Rien ici.", "Nothing here."))
                        .font(T.police(13)).foregroundStyle(T.doux).padding(.top, 30)
                }
            }
            .padding(.bottom, 8)
        }
        if !m.sortieBrew.isEmpty {
            DisclosureGroup(isExpanded: $etat.sortieOuverte) {
                ScrollView {
                    Text(m.sortieBrew).font(.system(size: 11, design: .monospaced)).foregroundStyle(T.doux)
                        .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }
                .frame(height: 140).padding(8).verre(8)
            } label: {
                Text(L.t("Sortie Homebrew", "Homebrew output")).font(T.police(11, .semibold)).foregroundStyle(T.doux)
            }
        }
    }
}

// MARK: - Journal : du plus récent au plus ancien

enum Periode: Int, CaseIterable, Identifiable {
    case jour = 1, sept = 7, trente = 30, tout = 0
    var id: Int { rawValue }
    var libelle: String {
        switch self {
        case .jour: L.t("Dernières 24 heures", "Last 24 hours")
        case .sept: L.t("7 derniers jours", "Last 7 days")
        case .trente: L.t("30 derniers jours", "Last 30 days")
        case .tout: L.t("Tout", "All")
        }
    }
}

final class EtatJournal: ObservableObject {
    @Published var periode: Periode = .jour
}

struct JournalVue: View {
    @EnvironmentObject var m: Moteur
    @StateObject private var etat = EtatJournal()

    private var entrees: [EntreeJournal] {
        guard etat.periode != .tout else { return m.historique }
        let depuis = Calendar.current.date(byAdding: .day, value: -etat.periode.rawValue, to: Date()) ?? .distantPast
        return m.historique.filter { $0.date >= depuis }
    }
    private static let format: DateFormatter = {
        let f = DateFormatter()
        f.locale = L.locale
        f.dateFormat = L.anglais ? "MM/dd/yyyy h:mm a" : "dd/MM/yyyy HH:mm"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ForEach(Periode.allCases) { p in
                    Button(p.libelle) { etat.periode = p }.buttonStyle(Puce(active: etat.periode == p))
                }
                Spacer()
                if !m.historique.isEmpty {
                    Button(L.t("Effacer la liste", "Clear the list")) { m.effacerJournal() }.buttonStyle(BoutonDiscret())
                }
            }
            .padding(.bottom, 4)
            HStack {
                Text("Date").frame(width: 130, alignment: .leading)
                Text(L.t("Application", "App")).frame(maxWidth: .infinity, alignment: .leading)
                Text("Versions").frame(width: 230, alignment: .leading)
                Text(L.t("Quoi", "Event")).frame(width: 110, alignment: .leading)
                Text(L.t("Par", "By")).frame(width: 110, alignment: .leading)
            }
            .font(T.police(11, .semibold)).foregroundStyle(T.tresDoux).padding(.horizontal, 12)
            if entrees.isEmpty {
                Text(L.t("Rien pour l'instant. Chaque mise à jour, installation ou désinstallation s'inscrira ici, y compris celles faites hors de l'app (repérées à la vérification suivante).", "Nothing yet. Every update, install or uninstall will be logged here, including those made outside the app (spotted at the next check)."))
                    .font(T.police(12)).foregroundStyle(T.doux).padding(.top, 20)
            }
            // Jusqu'à 20 lignes visibles, puis la liste défile.
            ListeAjustee(lignes: min(entrees.count, 500), maxLignes: 20) {
                VStack(spacing: 4) {
                    ForEach(entrees.prefix(500)) { e in
                        HStack {
                            Text(Self.format.string(from: e.date)).foregroundStyle(T.doux).frame(width: 130, alignment: .leading)
                            Text(e.nom).font(T.police(12, .semibold)).foregroundStyle(T.texte).lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            HStack(spacing: 4) {
                                Text(e.avant ?? "–").foregroundStyle(T.versionActuelle)
                                Image(systemName: "arrow.right").font(.system(size: 9, weight: .bold)).foregroundStyle(T.tresDoux)
                                Text(e.apres ?? "–").foregroundStyle(T.versionNouvelle)
                            }
                            .lineLimit(1).frame(width: 230, alignment: .leading)
                            Text(Self.libelle(e.quoi)).foregroundStyle(couleur(e.quoi)).frame(width: 110, alignment: .leading)
                            Text(Self.libelle(e.par)).foregroundStyle(T.tresDoux).frame(width: 110, alignment: .leading)
                        }
                        .font(T.police(12))
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .verre(8)
                    }
                }
            }
        }
    }

    /// Le journal est enregistré en français : traduit à l'affichage.
    static func libelle(_ x: String) -> String {
        guard L.anglais else { return x }
        switch x {
        case "Mise à jour": return "Updated"
        case "Réinstallée": return "Reinstalled"
        case "Installée": return "Installed"
        case "Désinstallée": return "Uninstalled"
        case "Disparue": return "Removed"
        case "hors de l'app": return "outside the app"
        case "Mises à jour": return "this app"
        case "Éditeur": return "Developer"
        default: return x
        }
    }

    private func couleur(_ quoi: String) -> Color {
        switch quoi {
        case "Mise à jour", "Réinstallée": T.statut
        case "Installée": T.accent
        case "Désinstallée", "Disparue": T.framboise
        default: T.doux
        }
    }
}

// MARK: - Réglages

final class EtatReglages: ObservableObject {
    @Published var cleGemini = Resumeur.cle ?? ""
    @Published var verification: String?     // nil : rien à dire ; "" : clé valide ; sinon l'erreur
    @Published var enTest = false
    @Published var modele = Resumeur.modele
}

struct ReglagesVue: View {
    @EnvironmentObject var m: Moteur
    @StateObject private var etat = EtatReglages()

    var body: some View {
        ListeAjustee(lignes: 8, maxLignes: 40) {
            // Deux colonnes : la page tenait sur un quart de la largeur.
            HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 14) {
                rubrique(L.t("Apparence", "Appearance")) {
                    ligne(L.t("Thème", "Theme"), L.t("Bleu nuit, Violine, ou Graphite : le gris presque noir des apps en mode sombre.", "Midnight blue, Violet, or Graphite: the near-black grey of dark-mode apps.")) {
                        Deroulant(valeur: $m.theme, options: ThemeNom.allCases.map { ($0, $0.libelle) })
                    }
                    ligne(L.t("Langue", "Language"), L.t("Automatique : celle du système.", "Automatic: the system language.")) {
                        Deroulant(valeur: $m.langue, options: Langue.allCases.map { ($0, $0.libelle) })
                    }
                    ligne(L.t("Afficher l'app dans", "Show the app in"), L.t("Dans le Dock, l'icône porte le nombre de mises à jour, et un clic ouvre la fenêtre.", "In the Dock, the icon shows the number of updates, and a click opens the window.")) {
                        Deroulant(valeur: $m.affichage, options: Affichage.allCases.map { ($0, $0.libelle) })
                    }
                }
                rubrique(L.t("Vérification", "Checking")) {
                    ligne(L.t("Vérification automatique", "Automatic check"), L.t("En plus de celle faite à chaque lancement.", "On top of the check made at every launch.")) {
                        Deroulant(valeur: $m.frequence, options: [1, 3, 6, 12, 24].map { h in
                            (h, h == 24 ? L.t("1 fois par jour", "once a day") : L.t("toutes les \(h) h", "every \(h) h"))
                        })
                    }
                    ligne(L.t("Délai avant de proposer une version", "Delay before offering a version"), L.t("Une nouvelle version n'est proposée qu'une fois « éprouvée » : sortie depuis ce nombre de jours.", "A new version is only offered once “proven”: out for this many days.")) {
                        Deroulant(valeur: $m.delai, options: [0, 1, 7, 15].map { j in (j, j == 0 ? L.t("Aucun", "None") : L.t("\(j) jours", "\(j) days")) })
                    }
                    ligne(L.t("Notifications", "Notifications"), L.t("Une notification macOS quand une nouvelle mise à jour apparaît.", "A macOS notification when a new update shows up.")) {
                        Toggle("", isOn: $m.notifications).toggleStyle(Interrupteur()).labelsHidden()
                    }
                }
                rubrique(L.t("Démarrage", "Startup")) {
                    ligne(L.t("Ouvrir à la connexion", "Open at login"), L.t("L'app se lance seule à l'ouverture de ta session.", "The app starts by itself when you log in.")) {
                        Toggle("", isOn: Binding(get: { m.lancementSession }, set: { m.basculerLancementSession($0) }))
                            .toggleStyle(Interrupteur()).labelsHidden()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .top)
            VStack(alignment: .leading, spacing: 14) {
                rubrique(L.t("Mises à jour", "Updates")) {
                    ligne(L.t("Mises à jour automatiques", "Automatic updates"), L.t("À chaque vérification, les apps proposées s'installent seules. Jamais les apps ouvertes, celles qui demandent ton mot de passe, ni les versions majeures.", "At every check, offered updates install by themselves. Never open apps, apps that need your password, or major versions.")) {
                        Toggle("", isOn: $m.automatique).toggleStyle(Interrupteur()).labelsHidden()
                    }
                    ligne(L.t("Fermer les apps sans demander", "Quit apps without asking"), L.t("Avant de mettre à jour une app ouverte, elle est fermée sans question (puis rouverte).", "Before updating an open app, it is quit without asking (then reopened).")) {
                        Toggle("", isOn: Binding(get: { UserDefaults.standard.bool(forKey: "fermerSansDemander") },
                                                 set: { UserDefaults.standard.set($0, forKey: "fermerSansDemander"); m.objectWillChange.send() }))
                            .toggleStyle(Interrupteur()).labelsHidden()
                    }
                }
                rubrique(L.t("Résumés des nouveautés", "What's new summaries")) {
                    ligne("Gemini", L.t("Gemini résume en deux phrases les notes de version des mises à jour proposées, avec ta propre clé d'API (aistudio.google.com). Seules les notes de version lui sont envoyées.", "Gemini summarizes the release notes of offered updates in two sentences, with your own API key (aistudio.google.com). Only the release notes are sent.")) {
                        Toggle("", isOn: $m.gemini).toggleStyle(Interrupteur()).labelsHidden()
                    }
                    if m.gemini {
                        ligne(L.t("Clé d'API", "API key"), L.t("Rangée sur ce Mac, dans le dossier de l'app, lisible par ton seul compte.", "Stored on this Mac, in the app folder, readable by your account only.")) {
                            HStack(spacing: 6) {
                                if etat.enTest {
                                    ProgressView().controlSize(.small)
                                } else if let v = etat.verification {
                                    Image(systemName: v.isEmpty ? "checkmark.circle.fill" : "xmark.circle.fill")
                                        .foregroundStyle(v.isEmpty ? T.statut : T.framboise)
                                        .help(v.isEmpty ? L.t("Clé valide, enregistrée (modèle \(etat.modele))", "Valid key, saved (model \(etat.modele))") : v)
                                }
                                SecureField(L.t("Clé d'API", "API key"), text: $etat.cleGemini)
                                    .textFieldStyle(.plain).font(T.police(12)).foregroundStyle(T.texte)
                                    .padding(.horizontal, 10).padding(.vertical, 5).verre(8).frame(width: 170)
                                    // Un collage depuis le Terminal apporte un retour à la ligne : on le retire.
                                    .onChange(of: etat.cleGemini) { _, v in
                                        let propre = v.filter { !$0.isWhitespace && !$0.isNewline }
                                        if propre != v { etat.cleGemini = propre }
                                        etat.verification = nil
                                    }
                                    .onSubmit { enregistrerCle() }
                                Button(L.t("Enregistrer", "Save")) { enregistrerCle() }.buttonStyle(BoutonDiscret()).disabled(etat.enTest)
                            }
                        }
                    }
                }
                rubrique(L.t("Avancé", "Advanced")) {
                    ligne(L.t("Apps ignorées", "Ignored apps"), L.t("Elles se retrouvent dans le filtre « Ignorées » de l'onglet Applications, un clic droit les fait suivre à nouveau.", "They are listed under “Ignored” in the Apps tab; right-click to track them again.")) {
                        Text("\(m.apps.filter { m.estIgnoree($0) }.count)").font(T.police(14, .bold)).foregroundStyle(T.accent)
                    }
                    ligne(L.t("Règles", "Rules"), L.t("Pour une app sans autre source : {\"bundleId\": \"…\", \"depot\": \"proprietaire/depot\"} pour GitHub, ou {\"bundleId\": \"…\", \"json\": \"adresse\", \"chemin\": \"mac.version\"} pour une adresse de l'éditeur.", "For an app with no other source: {\"bundleId\": \"…\", \"depot\": \"owner/repo\"} for GitHub, or {\"bundleId\": \"…\", \"json\": \"url\", \"chemin\": \"mac.version\"} for a developer URL.")) {
                        Button(L.t("Afficher le fichier", "Show file")) { NSWorkspace.shared.activateFileViewerSelecting([Regles.fichier]) }
                            .buttonStyle(BoutonDiscret())
                    }
                    ligne(L.t("Données de l'app", "App data"), L.t("Journal, versions vues, règles.", "Log, seen versions, rules.")) {
                        Button(L.t("Ouvrir le dossier", "Open folder")) { NSWorkspace.shared.open(Dossiers.support) }.buttonStyle(BoutonDiscret())
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .top)
            }
        }
    }

    /// Vérifie la clé auprès de Gemini avant de l'enregistrer, et affiche ✓ ou ✗.
    private func enregistrerCle() {
        let cle = etat.cleGemini
        etat.enTest = true
        Task {
            switch await Resumeur.tester(cle) {
            case .success(let modele):
                etat.enTest = false
                etat.verification = ""
                etat.modele = modele
                Resumeur.cle = cle
                await m.resumer()
            case .failure(let e):
                etat.enTest = false
                etat.verification = e.localizedDescription
            }
        }
    }

    /// Une rubrique : petit titre, puis ses lignes dans un même cadre, séparées d'un filet.
    private func rubrique<C: View>(_ titre: String, @ViewBuilder _ lignes: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(titre.uppercased()).font(T.police(10, .semibold)).foregroundStyle(T.tresDoux).padding(.leading, 4)
            _VariadicView.Tree(Filets()) { lignes() }
                .verre(12)
        }
    }

    /// Une ligne : le nom à gauche (l'explication au survol de ⓘ), le contrôle à droite.
    private func ligne<C: View>(_ titre: String, _ aide: String, @ViewBuilder _ controle: () -> C) -> some View {
        HStack(spacing: 8) {
            Text(titre).font(T.police(13, .medium)).foregroundStyle(T.texte)
            Info(texte: aide)
            Spacer(minLength: 12)
            controle()
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
    }
}

/// Les lignes d'une rubrique, séparées par un filet fin.
private struct Filets: _VariadicView_MultiViewRoot {
    func body(children: _VariadicView.Children) -> some View {
        VStack(spacing: 0) {
            ForEach(children) { enfant in
                enfant
                if enfant.id != children.last?.id { Rectangle().fill(T.trait).frame(height: 0.5).padding(.horizontal, 14) }
            }
        }
    }
}

/// Menu déroulant dans le style de l'app : la valeur choisie et un chevron ; un clic ouvre la liste.
struct Deroulant<V: Hashable>: View {
    @Binding var valeur: V
    let options: [(V, String)]

    var body: some View {
        Menu {
            ForEach(options, id: \.0) { o in
                Button { valeur = o.0 } label: {
                    if o.0 == valeur { Label(o.1, systemImage: "checkmark") } else { Text(o.1) }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(options.first { $0.0 == valeur }?.1 ?? "")
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
            }
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(BoutonDiscret())
        .fixedSize()
    }
}

// MARK: - Désinstallation

final class EtatDesinstallation: ObservableObject {
    @Published var residus: [Residu] = []
    @Published var charge = false
    @Published var enCours = false
    @Published var erreur: String?
}

struct DesinstallationVue: View {
    @EnvironmentObject var m: Moteur
    @Environment(\.dismiss) private var fermer
    @StateObject private var etat = EtatDesinstallation()
    let app: AppInstallee

    private var total: Int64 { etat.residus.filter(\.coche).compactMap(\.taille).reduce(0, +) }

    var body: some View {
        ZStack {
            FondTheme()
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(nsImage: Icones.icone(app.chemin)).resizable().frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L.t("Désinstaller \(app.nom)", "Uninstall \(app.nom)")).font(T.police(18, .bold)).foregroundStyle(T.texte)
                        Text(L.t("Tout part à la Corbeille : rien n'est effacé tant qu'elle n'est pas vidée.", "Everything goes to the Trash: nothing is deleted until you empty it."))
                            .font(T.police(11)).foregroundStyle(T.doux)
                    }
                }
                if !etat.charge {
                    HStack { ProgressView().controlSize(.small); Text(L.t("Recherche des fichiers…", "Looking for files…")).font(T.police(12)).foregroundStyle(T.doux) }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(spacing: 4) {
                            ForEach($etat.residus) { $r in
                                HStack(spacing: 10) {
                                    Toggle("", isOn: $r.coche).toggleStyle(.checkbox).labelsHidden()
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text((r.chemin as NSString).lastPathComponent).font(T.police(12, .semibold)).foregroundStyle(T.texte).lineLimit(1)
                                        Text((r.chemin as NSString).deletingLastPathComponent).font(T.police(10)).foregroundStyle(T.tresDoux)
                                            .lineLimit(1).truncationMode(.middle)
                                    }
                                    Spacer(minLength: 8)
                                    Text(r.raison).font(T.police(10)).foregroundStyle(r.douteux || r.protege ? T.ambre : T.tresDoux)
                                    Text(r.taille.map(Desinstalleur.lisible) ?? "—").font(T.police(11, .medium)).foregroundStyle(T.doux)
                                        .frame(width: 80, alignment: .trailing)
                                }
                                .padding(.horizontal, 10).padding(.vertical, 6).verre(8)
                            }
                        }
                    }
                }
                if etat.residus.contains(where: \.protege) {
                    HStack(spacing: 10) {
                        Text(L.t("Les dossiers « protégés par macOS » ne peuvent partir qu'avec l'Accès complet au disque accordé à Mises à jour.", "Folders “protected by macOS” can only be removed once this app has Full Disk Access."))
                            .font(T.police(11)).foregroundStyle(T.ambre).fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button(L.t("Ouvrir les réglages", "Open Settings")) {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                        }
                        .buttonStyle(BoutonDiscret())
                    }
                }
                if let e = etat.erreur { Text(e).font(T.police(11)).foregroundStyle(T.framboise).lineLimit(3) }
                HStack {
                    Text(L.t("\(etat.residus.filter(\.coche).count) élément(s) · \(Desinstalleur.lisible(total))", "\(etat.residus.filter(\.coche).count) item(s) · \(Desinstalleur.lisible(total))"))
                        .font(T.police(12, .semibold)).foregroundStyle(T.doux)
                    Spacer()
                    Button(L.t("Annuler", "Cancel")) { fermer() }.buttonStyle(BoutonDiscret()).keyboardShortcut(.cancelAction)
                    Button(etat.enCours ? L.t("En cours…", "Working…") : L.t("Mettre à la Corbeille", "Move to Trash")) {
                        Task {
                            etat.enCours = true
                            let chemins = etat.residus.filter(\.coche).map(\.chemin)
                            etat.erreur = await m.desinstaller(app, chemins)
                            etat.enCours = false
                            if etat.erreur == nil { fermer() }
                        }
                    }
                    .buttonStyle(BoutonPlein(teinte: Boutons.danger))
                    .disabled(etat.enCours || !etat.charge || !etat.residus.contains(where: \.coche))
                }
            }
            .padding(20)
        }
        .frame(width: 720, height: 520)
        .preferredColorScheme(.dark)
        .task {
            let a = app
            etat.residus = await Task.detached { Desinstalleur.chercher(a) }.value
            etat.charge = true
        }
    }
}

// MARK: - Panneau de la barre des menus

struct PanneauMenu: View {
    @EnvironmentObject var m: Moteur

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L.t("Mises à jour", "App Updater")).font(T.police(15, .bold)).foregroundStyle(T.texte)
                Spacer()
                if let l = m.lot {
                    Text("\(l.fait) / \(l.total)").font(T.police(11, .semibold)).foregroundStyle(T.statut)
                }
                if m.enCours {
                    ProgressView().controlSize(.small)
                } else {
                    Button { Task { await m.verifier() } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.plain).foregroundStyle(T.doux).help(L.t("Vérifier maintenant", "Check now"))
                }
            }
            Text(sousTitre).font(T.police(11)).foregroundStyle(T.doux)
            if let p = m.nouvelleVersionApp {
                Text(L.t("Nouvelle version de l'app : \(p.version)", "New version of the app: \(p.version)"))
                    .font(T.police(11, .semibold)).foregroundStyle(T.accent)
            }
            if let msg = m.message {
                Text(msg).font(T.police(10)).foregroundStyle(T.ambre).lineLimit(2)
            }
            if !m.aMettreAJour.isEmpty {
                ScrollView {
                    VStack(spacing: 5) { ForEach(m.aMettreAJour) { LigneApp(app: $0, compacte: true) } }
                }
                .frame(height: min(CGFloat(m.aMettreAJour.count) * 45, 360) + CGFloat(m.progression.count) * 30)
            }
            HStack {
                if !m.cochables.isEmpty {
                    Button(L.t("Tout mettre à jour (\(m.cochables.count))", "Update all (\(m.cochables.count))")) { Task { await m.toutMettreAJour() } }
                        .buttonStyle(BoutonPlein(teinte: Boutons.mettreAJour)).disabled(m.lot != nil)
                }
                Spacer()
                Button(L.t("Liste complète", "Full list")) { m.montrerFenetre?() }
                .buttonStyle(BoutonDiscret())
            }
            Divider().overlay(T.trait)
            HStack {
                Spacer()
                Button(L.t("Quitter", "Quit")) { NSApp.terminate(nil) }.buttonStyle(.plain).font(T.police(11)).foregroundStyle(T.doux)
            }
        }
        .padding(14)
        .frame(width: 480)
        .background(FondTheme())
        .preferredColorScheme(.dark)
        .id("\(m.theme.rawValue)-\(m.langue.rawValue)")
    }

    private var sousTitre: String {
        if m.enCours && m.apps.isEmpty { return L.t("Première vérification en cours…", "First check in progress…") }
        let n = m.aMettreAJour.count
        let debut = n == 0 ? L.t("Tout est à jour", "Everything is up to date") : (n == 1 ? L.t("1 mise à jour disponible", "1 update available") : L.t("\(n) mises à jour disponibles", "\(n) updates available"))
        guard let d = m.derniereVerif else { return debut }
        return debut + L.t(" · vérifié à \(d.formatted(date: .omitted, time: .shortened))", " · checked at \(d.formatted(date: .omitted, time: .shortened))")
    }
}

// MARK: - Liste qui prend la hauteur de son contenu, et défile au-delà de 30 lignes

struct HauteurCle: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

final class Mesure: ObservableObject {
    @Published var hauteur: CGFloat = 0
}

struct ListeAjustee<Contenu: View>: View {
    let lignes: Int
    var maxLignes = 30
    @ViewBuilder let contenu: () -> Contenu
    @StateObject private var mesure = Mesure()

    var body: some View {
        ScrollView {
            contenu()
                .background(GeometryReader { g in Color.clear.preference(key: HauteurCle.self, value: g.size.height) })
        }
        .onPreferenceChange(HauteurCle.self) { h in mesure.hauteur = h }
        .frame(height: plafond)
    }

    /// Au-delà de `maxLignes`, la hauteur de `maxLignes` lignes moyennes ; en deçà, tout le contenu ; jamais plus que l'écran.
    private var plafond: CGFloat {
        let trente = lignes > maxLignes ? mesure.hauteur / CGFloat(lignes) * CGFloat(maxLignes) : mesure.hauteur
        // Et jamais plus que l'écran, moins la place de l'en-tête, des filtres et de la barre de titre.
        let ecran = (NSScreen.main?.visibleFrame.height ?? 900) - 300
        return min(trente, max(ecran, 200))
    }
}

// MARK: - ⓘ : l'explication d'un réglage, affichée au survol
// (l'infobulle système ne s'affichait pas : l'app de barre des menus n'est pas « active » au survol)

final class Survol: ObservableObject {
    @Published var visible = false
}

struct Info: View {
    let texte: String
    @StateObject private var survol = Survol()

    var body: some View {
        Image(systemName: "info.circle")
            .font(.system(size: 11))
            .foregroundStyle(survol.visible ? T.texte : T.tresDoux)
            .contentShape(Rectangle())
            .onHover { survol.visible = $0 }
            .popover(isPresented: $survol.visible, arrowEdge: .bottom) {
                Text(texte)
                    .font(T.police(12))
                    .foregroundStyle(T.texte)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 280, alignment: .leading)
                    .padding(12)
            }
    }
}
