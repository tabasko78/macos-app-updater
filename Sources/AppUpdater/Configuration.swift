import Foundation

/// Réglages propres à une copie de l'app, lus dans Contents/Resources/perso.json s'il existe.
/// La version publiée sur GitHub n'en a pas : thème Graphite, langue du système.
enum ConfigApp {
    struct Perso: Decodable {
        var theme: String?
        var langue: String?
        var perso: [String]?     // noms d'apps à classer « Perso » d'office
    }

    static let perso: Perso? = Bundle.main.url(forResource: "perso", withExtension: "json")
        .flatMap { try? Data(contentsOf: $0) }
        .flatMap { try? JSONDecoder().decode(Perso.self, from: $0) }

    static var themeParDefaut: ThemeNom { perso?.theme.flatMap(ThemeNom.init(rawValue:)) ?? .graphite }
    static var langueParDefaut: Langue { perso?.langue.flatMap(Langue.init(rawValue:)) ?? .auto }
    static var appsPerso: Set<String> { Set(perso?.perso ?? []) }
}

/// Langue de l'interface : celle du système (français s'il est en français, anglais sinon), ou forcée.
enum Langue: String, CaseIterable, Identifiable {
    case auto, fr, en
    var id: String { rawValue }
    var libelle: String {
        switch self {
        case .auto: L.t("Automatique", "Automatic")
        case .fr: "Français"
        case .en: "English"
        }
    }
}

/// Où l'app se montre : barre des menus, Dock, ou les deux.
enum Affichage: String, CaseIterable, Identifiable {
    case menu, dock, lesDeux
    var id: String { rawValue }
    var libelle: String {
        switch self {
        case .menu: L.t("Barre des menus", "Menu bar")
        case .dock: "Dock"
        case .lesDeux: L.t("Les deux", "Both")
        }
    }
    var menu: Bool { self != .dock }
    var dock: Bool { self != .menu }
}

enum L {
    static var choix: Langue {
        UserDefaults.standard.string(forKey: "langue").flatMap(Langue.init(rawValue:)) ?? ConfigApp.langueParDefaut
    }

    static var anglais: Bool {
        switch choix {
        case .fr: false
        case .en: true
        case .auto: !(Locale.preferredLanguages.first ?? "en").hasPrefix("fr")
        }
    }

    /// Le texte dans la langue de l'interface.
    static func t(_ fr: String, _ en: String) -> String { anglais ? en : fr }

    static var locale: Locale { Locale(identifier: anglais ? "en_US" : "fr_FR") }
}
