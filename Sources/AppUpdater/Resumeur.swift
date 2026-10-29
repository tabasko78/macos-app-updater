import Foundation

/// Résumé des notes de version par Gemini, avec la clé de chaque utilisateur (Réglages).
/// La clé est rangée dans le dossier de l'app, lisible par son seul compte, jamais dans le code ni sur GitHub.
/// Les résumés sont gardés en cache : une version n'est résumée qu'une fois.
enum Resumeur {
    private static var fichierCle: URL { Dossiers.support.appendingPathComponent("gemini.key") }
    private static var fichierCache: URL { Dossiers.caches.appendingPathComponent("resumes.json") }

    static var cle: String? {
        get {
            (try? String(contentsOf: fichierCle, encoding: .utf8))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .flatMap { $0.isEmpty ? nil : $0 }
        }
        set {
            if let v = newValue?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty {
                try? v.write(to: fichierCle, atomically: true, encoding: .utf8)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fichierCle.path)
            } else {
                try? FileManager.default.removeItem(at: fichierCle)
            }
        }
    }

    /// bundle id@version → résumé
    static func cache() -> [String: String] {
        (try? Data(contentsOf: fichierCache)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
    }

    static func enregistrer(_ c: [String: String]) {
        try? JSONEncoder().encode(c).write(to: fichierCache, options: .atomic)
    }

    /// Les notes de l'app : celles de la source, sinon la page de notes de Sparkle, débarrassées du HTML.
    static func notes(_ a: AppInstallee) async -> String? {
        var texte = a.notes
        if (texte ?? "").isEmpty, let u = a.notesLien, let (d, _) = try? await URLSession.shared.data(from: u) {
            texte = String(decoding: d, as: UTF8.self)
        }
        // Homebrew ne publie pas de notes : si l'app est publiée sur GitHub, celles de la publication.
        if (texte ?? "").isEmpty, let depot = depotGitHub(a), let v = a.disponible {
            texte = await notesGitHub(depot, version: v)
        }
        guard var t = texte else { return nil }
        t = t.replacingOccurrences(of: "<(script|style)[^>]*>[\\s\\S]*?</\\1>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return t.count < 20 ? nil : String(t.prefix(6000))
    }

    /// « proprietaire/depot » d'une app publiée sur GitHub : d'après l'adresse de téléchargement du cask
    /// (github.com/…/releases/download/…), ou le fichier app-update.yml d'une app Electron.
    static func depotGitHub(_ a: AppInstallee) -> String? {
        if let u = a.cask?.url, let r = u.range(of: "github.com/") {
            let morceaux = u[r.upperBound...].split(separator: "/")
            if morceaux.count >= 2 { return "\(morceaux[0])/\(morceaux[1])" }
        }
        return Regles.depuisElectron(a)?.depot
    }

    /// Notes de la publication GitHub de cette version (étiquette « v1.2.3 » ou « 1.2.3 »), sinon de la dernière.
    private static func notesGitHub(_ depot: String, version: String) async -> String? {
        for chemin in ["releases/tags/v\(version)", "releases/tags/\(version)", "releases/latest"] {
            var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(depot)/\(chemin)")!, timeoutInterval: 15)
            req.setValue("AppUpdater/1.0", forHTTPHeaderField: "User-Agent")
            guard let (d, rep) = try? await URLSession.shared.data(for: req), (rep as? HTTPURLResponse)?.statusCode == 200,
                  let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let corps = j["body"] as? String, !corps.isEmpty else { continue }
            return corps
        }
        return nil
    }

    /// B : sans notes nulle part, Gemini cherche les nouveautés sur le web (recherche Google) avant de résumer.
    static func resumerWeb(_ a: AppInstallee, cle: String) async throws -> String {
        let consigne = L.t(
            "Cherche sur le web les notes de version officielles de \(a.nom) version \(a.disponible ?? "") pour macOS. Résume en français, en deux phrases courtes au plus, ce que cette version apporte. Si tu ne trouves rien de fiable pour cette version précise, réponds seulement : RIEN. Pas d'introduction, pas de liste, pas de mise en forme, pas de source.",
            "Search the web for the official release notes of \(a.nom) version \(a.disponible ?? "") for macOS. Summarize in English, in two short sentences at most, what this version brings. If you find nothing reliable for this exact version, answer only: NOTHING. No introduction, no list, no formatting, no sources.")
        let r = try await appeler(consigne, cle: cle, rechercheWeb: true)
        let mot = r.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).uppercased()
        guard mot != "RIEN", mot != "NOTHING" else { throw ErreurSource("") }
        return r
    }

    static func resumer(_ a: AppInstallee, notes: String, cle: String) async throws -> String {
        let consigne = L.t(
            "Voici les notes de version de \(a.nom) \(a.disponible ?? ""). Résume en français, en deux phrases courtes au plus, ce que cette mise à jour apporte à l'utilisateur. Pas d'introduction, pas de liste, pas de mise en forme.",
            "Here are the release notes of \(a.nom) \(a.disponible ?? ""). Summarize in English, in two short sentences at most, what this update brings to the user. No introduction, no list, no formatting.")
        return try await appeler(consigne + "\n\n" + notes, cle: cle)
    }

    /// Modèles essayés dans l'ordre. Gemini 2.5 Flash est fermé aux nouvelles clés (octobre 2026), et
    /// 3.8 Flash n'a pas répondu en 60 s avec la clé gratuite (29/10/2026) : le premier qui répond est retenu.
    static let modeles = ["gemini-3.8-flash", "gemini-3.6-flash", "gemini-flash-latest", "gemini-3.5-flash-lite"]
    static var modele: String {
        get { UserDefaults.standard.string(forKey: "modeleGemini") ?? modeles[0] }
        set { UserDefaults.standard.set(newValue, forKey: "modeleGemini") }
    }

    /// Vérifie la clé avant de l'enregistrer : essaie les modèles (20 s chacun) et retient le premier qui répond.
    /// Renvoie le modèle retenu, ou l'erreur du dernier essai.
    static func tester(_ cle: String) async -> Result<String, Error> {
        var derniere: Error = ErreurSource(L.t("aucun modèle n'a répondu", "no model answered"))
        for m in modeles {
            do {
                _ = try await appeler("Reply with the single word: ok", cle: cle, modele: m, delai: 20)
                modele = m
                return .success(m)
            } catch {
                derniere = error
                // Clé refusée : inutile d'essayer les autres modèles.
                if error.localizedDescription.localizedCaseInsensitiveContains("API key") { break }
            }
        }
        return .failure(derniere)
    }

    private static func appeler(_ texte: String, cle: String, modele m: String? = nil, delai: TimeInterval = 60, rechercheWeb: Bool = false) async throws -> String {
        var req = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(m ?? modele):generateContent")!, timeoutInterval: delai)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(cle, forHTTPHeaderField: "x-goog-api-key")
        var corps: [String: Any] = [
            "contents": [["parts": [["text": texte]]]],
            "generationConfig": ["temperature": 0.2, "maxOutputTokens": 1024],
        ]
        if rechercheWeb { corps["tools"] = [["google_search": [String: Any]()]] }
        req.httpBody = try JSONSerialization.data(withJSONObject: corps)
        let (data, rep) = try await URLSession.shared.data(for: req)
        let j = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let h = rep as? HTTPURLResponse, h.statusCode != 200 {
            let m = (j?["error"] as? [String: Any])?["message"] as? String
            throw ErreurSource("Gemini : " + (m ?? "\(h.statusCode)"))
        }
        Consommation.ajouter(modele: m ?? modele, reponse: j)
        let parties = ((j?["candidates"] as? [[String: Any]])?.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]]
        guard let texte = parties?.compactMap({ $0["text"] as? String }).joined(), !texte.isEmpty else {
            throw ErreurSource(L.t("Gemini n'a rien répondu", "Gemini gave no answer"))
        }
        return texte.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Ce que Gemini a consommé avec la clé de l'app, cumulé depuis le premier appel et jamais remis à zéro :
/// par modèle, nombre d'appels, jetons envoyés et reçus (réflexion comprise), recherches web.
enum Consommation {
    struct Compte: Codable { var appels = 0; var entree = 0; var sortie = 0; var recherches = 0 }
    private static var fichier: URL { Dossiers.support.appendingPathComponent("gemini-consommation.json") }
    private static let verrou = NSLock()

    static func lire() -> [String: Compte] {
        (try? Data(contentsOf: fichier)).flatMap { try? JSONDecoder().decode([String: Compte].self, from: $0) } ?? [:]
    }

    static func ajouter(modele: String, reponse j: [String: Any]?) {
        guard let u = j?["usageMetadata"] as? [String: Any] else { return }
        verrou.lock(); defer { verrou.unlock() }
        var tout = lire()
        var c = tout[modele] ?? Compte()
        c.appels += 1
        c.entree += (u["promptTokenCount"] as? Int ?? 0) + (u["toolUsePromptTokenCount"] as? Int ?? 0)
        c.sortie += (u["candidatesTokenCount"] as? Int ?? 0) + (u["thoughtsTokenCount"] as? Int ?? 0)
        let ancrage = ((j?["candidates"] as? [[String: Any]])?.first?["groundingMetadata"] as? [String: Any])
        c.recherches += (ancrage?["webSearchQueries"] as? [Any])?.count ?? 0
        tout[modele] = c
        try? JSONEncoder().encode(tout).write(to: fichier, options: .atomic)
    }
}
