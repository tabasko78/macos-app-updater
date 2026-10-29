import Foundation

@main
enum Demarrage {
    static func main() {
        // « AppUpdater --rapport » : la vérification complète en texte, sans interface, sans rien installer.
        if CommandLine.arguments.contains("--rapport") {
            let fin = DispatchSemaphore(value: 0)
            Task.detached {
                await rapport()
                fin.signal()
            }
            fin.wait()
            return
        }
        // « AppUpdater --residus <app> » : ce que la désinstallation proposerait, sans rien toucher.
        if let i = CommandLine.arguments.firstIndex(of: "--residus"), i + 1 < CommandLine.arguments.count {
            guard let a = Inventaire.lire(chemin: CommandLine.arguments[i + 1]) else { print("app illisible ou app d'Apple"); return }
            for r in Desinstalleur.chercher(a) {
                print("\(r.coche ? "[x]" : "[ ]") \(r.taille.map(Desinstalleur.lisible) ?? "—") · \(r.raison) · \(r.chemin)")
            }
            return
        }
        // « AppUpdater --essai-installation <app> » : télécharge, vérifie et contrôle la nouvelle version, sans rien remplacer.
        if let i = CommandLine.arguments.firstIndex(of: "--essai-installation"), i + 1 < CommandLine.arguments.count {
            let chemin = CommandLine.arguments[i + 1]
            Task.detached {
                let r = await Verification.tout()
                guard let a = r.apps.first(where: { $0.chemin == chemin }), case .installer(let u, let sha) = a.action else {
                    print("pas d'installation directe pour cette app"); exit(1)
                }
                do {
                    print("téléchargement de \(u.absoluteString)")
                    let f = try await Installeur.telecharger(u) { _, _ in }
                    if let sha { print("empreinte", try Installeur.empreinte(f) == sha.lowercased() ? "conforme" : "INCORRECTE") }
                    let n = try await Installeur.extraire(f)
                    print("extrait :", n.path)
                    try await Installeur.controler(n, contre: a)
                    print("contrôle de l'app et de la signature : conforme, équipe", await Installeur.equipe(n.path) ?? "aucune")
                    Installeur.nettoyer(f)
                    exit(0)
                } catch { print("échec :", error.localizedDescription); exit(1) }
            }
            dispatchMain()
        }
        // « AppUpdater --index-brew <fichier> » : second processus qui fabrique l'index Homebrew réduit.
        if let i = CommandLine.arguments.firstIndex(of: "--index-brew"), i + 1 < CommandLine.arguments.count {
            let chemin = CommandLine.arguments[i + 1]
            Task.detached { exit(await Homebrew.construireIndex(vers: chemin)) }
            dispatchMain()
        }
        AppUpdaterApp.main()
    }

    static func rapport() async {
        let r = await Verification.tout()
        for e in r.erreurs { print("ERREUR \(e)") }
        let tri = r.apps.sorted { ($0.aJour == false ? 0 : 1, $0.nom.lowercased()) < ($1.aJour == false ? 0 : 1, $1.nom.lowercased()) }
        for a in tri {
            let etat = a.aJour == nil ? "?" : (a.aJour! ? "ok" : "MAJ")
            var action = ""
            switch a.action {
            case .brew(let t, let term): action = "brew \(t)\(term ? " (terminal)" : "")"
            case .installer(let u, let sha): action = "installer \(u.lastPathComponent)\(sha != nil ? " (empreinte)" : "")"
            case .appStore: action = "App Store"
            case .telecharger: action = "télécharger"
            case .ouvrirApp: action = "ouvrir l'app"
            case .page: action = "page"
            case .aucune: action = ""
            }
            let ligne = [etat, a.nom, a.versionAffichee + (a.build.isEmpty || a.build == a.version ? "" : " (\(a.build))"), a.disponible ?? "-", a.source.rawValue, action, a.remarque ?? ""]
            print(ligne.joined(separator: " | "))
        }
    }
}
