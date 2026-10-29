import Foundation

/// Comparaison de numéros de version tolérante : « 1.10 » > « 1.9 », « 2.0 » = « 2.0.0 », « 2.0b3 » < « 2.0 ».
enum Versions {
    static func plusRecent(_ a: String, que b: String) -> Bool {
        comparer(a, b) == .orderedDescending
    }

    static func comparer(_ a: String, _ b: String) -> ComparisonResult {
        let x = morceaux(a), y = morceaux(b)
        var i = 0
        while true {
            switch (i < x.count ? x[i] : nil, i < y.count ? y[i] : nil) {
            case let (p?, q?):
                let pn = estNombre(p), qn = estNombre(q)
                if pn && qn {
                    let c = numerique(p, q)
                    if c != .orderedSame { return c }
                } else if pn != qn {
                    return pn ? .orderedDescending : .orderedAscending
                } else {
                    let c = p.lowercased().compare(q.lowercased())
                    if c != .orderedSame { return c }
                }
            case (_?, nil):
                return queue(Array(x[i...]))
            case (nil, _?):
                switch queue(Array(y[i...])) {
                case .orderedAscending: return .orderedDescending
                case .orderedDescending: return .orderedAscending
                case .orderedSame: return .orderedSame
                }
            case (nil, nil):
                return .orderedSame
            }
            i += 1
        }
    }

    /// Ce qui reste d'une version plus longue que l'autre : des zéros ne comptent pas,
    /// une lettre (beta, rc, b) la rend plus ancienne, un chiffre plus récente.
    private static func queue(_ reste: [String]) -> ComparisonResult {
        if reste.allSatisfy({ estNombre($0) && $0.allSatisfy { $0 == "0" } }) { return .orderedSame }
        return estNombre(reste[0]) ? .orderedDescending : .orderedAscending
    }

    private static func numerique(_ p: String, _ q: String) -> ComparisonResult {
        let a = p.drop { $0 == "0" }, b = q.drop { $0 == "0" }
        if a.count != b.count { return a.count < b.count ? .orderedAscending : .orderedDescending }
        return String(a).compare(String(b))
    }

    private static func estNombre(_ s: String) -> Bool { s.first.map { $0.isASCII && $0.isNumber } ?? false }

    static func morceaux(_ v: String) -> [String] {
        var r: [String] = [], cur = ""
        var curChiffre: Bool? = nil
        for ch in v {
            let chiffre = ch.isASCII && ch.isNumber
            guard chiffre || ch.isLetter else {
                if !cur.isEmpty { r.append(cur); cur = "" }
                curChiffre = nil
                continue
            }
            if let c = curChiffre, c != chiffre, !cur.isEmpty { r.append(cur); cur = "" }
            cur.append(ch)
            curChiffre = chiffre
        }
        if !cur.isEmpty { r.append(cur) }
        return r
    }
}
