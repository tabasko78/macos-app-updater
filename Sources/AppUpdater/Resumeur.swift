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

    static func resumer(_ a: AppInstallee, notes: String, cle: String) async throws -> String {
        let consigne = L.t(
            "Voici les notes de version de \(a.nom) \(a.disponible ?? ""). Résume en français, en deux phrases courtes au plus, ce que cette mise à jour apporte à l'utilisateur. Pas d'introduction, pas de liste, pas de mise en forme.",
            "Here are the release notes of \(a.nom) \(a.disponible ?? ""). Summarize in English, in two short sentences at most, what this update brings to the user. No introduction, no list, no formatting.")
        var req = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent")!, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(cle, forHTTPHeaderField: "x-goog-api-key")
        let corps: [String: Any] = [
            "contents": [["parts": [["text": consigne + "\n\n" + notes]]]],
            "generationConfig": ["temperature": 0.2, "maxOutputTokens": 200, "thinkingConfig": ["thinkingBudget": 0]],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: corps)
        let (data, rep) = try await URLSession.shared.data(for: req)
        let j = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let h = rep as? HTTPURLResponse, h.statusCode != 200 {
            let m = (j?["error"] as? [String: Any])?["message"] as? String
            throw ErreurSource("Gemini : " + (m ?? "\(h.statusCode)"))
        }
        let parties = ((j?["candidates"] as? [[String: Any]])?.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]]
        guard let texte = parties?.compactMap({ $0["text"] as? String }).joined(), !texte.isEmpty else {
            throw ErreurSource(L.t("Gemini n'a rien répondu", "Gemini gave no answer"))
        }
        return texte.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
