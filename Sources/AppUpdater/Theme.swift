import SwiftUI

// MARK: - Trois palettes : Bleu nuit, Violine, Graphite

enum ThemeNom: String, CaseIterable, Identifiable {
    case bleuNuit = "Bleu nuit"
    case violine = "Violine"
    case graphite = "Graphite"
    var id: String { rawValue }
    var libelle: String {
        switch self {
        case .bleuNuit: L.t("Bleu nuit", "Midnight blue")
        case .violine: L.t("Violine", "Violet")
        case .graphite: "Graphite"
        }
    }
}

struct Palette {
    let fond, texte, doux, tresDoux, accent, rose, cyan, ambre, framboise: UInt32
}

enum T {
    static let bleuNuit = Palette(fond: 0x04061a, texte: 0xe8ecff, doux: 0x98a2d6, tresDoux: 0x727cae, accent: 0x5b86ff,
                                  rose: 0xff6fb1, cyan: 0x3ee0ff, ambre: 0xffcf5c, framboise: 0xff5470)
    static let violine = Palette(fond: 0x0f0a1e, texte: 0xece7fb, doux: 0xa294c9, tresDoux: 0x8175a8, accent: 0xa78bfa,
                                 rose: 0xff7ac6, cyan: 0x67e8f9, ambre: 0xffc971, framboise: 0xff5c8a)

    static var nom: ThemeNom { ThemeNom(rawValue: UserDefaults.standard.string(forKey: "theme") ?? "") ?? ConfigApp.themeParDefaut }
    /// Graphite : le gris presque noir des apps en mode sombre (jamais du vrai noir), accents éteints.
    static let graphite = Palette(fond: 0x161618, texte: 0xe4e4e7, doux: 0x9d9da5, tresDoux: 0x6e6e76, accent: 0x8a93a3,
                                  rose: 0xc4899f, cyan: 0x86b3c4, ambre: 0xcfae6e, framboise: 0xcf616f)

    static var p: Palette {
        switch nom {
        case .bleuNuit: bleuNuit
        case .violine: violine
        case .graphite: graphite
        }
    }

    /// Force des halos de couleur du fond : discrets en Graphite.
    static var halos: Double { nom == .graphite ? 0.25 : 1 }

    static var fond: Color { Color(hex: p.fond) }
    static var texte: Color { Color(hex: p.texte) }
    static var doux: Color { Color(hex: p.doux) }
    static var tresDoux: Color { Color(hex: p.tresDoux) }
    static var accent: Color { Color(hex: p.accent) }
    static var rose: Color { Color(hex: p.rose) }
    static var cyan: Color { Color(hex: p.cyan) }
    static var ambre: Color { Color(hex: p.ambre) }
    static var framboise: Color { Color(hex: p.framboise) }
    static var trait: Color { accent.opacity(0.16) }

    /// Texte posé sur un aplat de couleur : noir au-dessus de 0,3 de luminance, blanc en dessous.
    static func sur(_ hex: UInt32) -> Color {
        func c(_ v: UInt32) -> Double {
            let x = Double(v) / 255
            return x <= 0.03928 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
        }
        let l = 0.2126 * c((hex >> 16) & 0xff) + 0.7152 * c((hex >> 8) & 0xff) + 0.0722 * c(hex & 0xff)
        return l > 0.3 ? Color(hex: 0x111111) : .white
    }

    static func police(_ t: CGFloat, _ w: Font.Weight = .regular) -> Font { .custom("Montserrat", size: t).weight(w) }

    static func hex(_ s: Source) -> UInt32 {
        switch s {
        case .homebrew: p.texte
        case .sparkle: p.rose
        case .appStore: p.cyan
        case .github, .editeur: p.accent
        case .composant, .integree, .abandonnee, .perso: p.doux
        case .aucune: p.tresDoux
        }
    }
    static func couleur(_ s: Source) -> Color { Color(hex: hex(s)) }
}

/// Teintes des boutons, une couleur = un geste. Chaque teinte est un dégradé sombre, de gauche à droite (90°).
struct Teinte {
    let gauche: UInt32
    let droite: UInt32
}

enum Boutons {
    // Bleu nuit : des bleus ; Violine : les mêmes rôles en violets ; Graphite : des gris, à peine teintés.
    // Lie-de-vin pour supprimer, partout.
    private static func choix(_ bleu: Teinte, _ violet: Teinte, _ gris: Teinte) -> Teinte {
        switch T.nom {
        case .bleuNuit: bleu
        case .violine: violet
        case .graphite: gris
        }
    }
    static var mettreAJour: Teinte {   // installe tout seul, onglet ou filtre choisi
        choix(Teinte(gauche: 0x2c4fae, droite: 0x16245c), Teinte(gauche: 0x6b42b8, droite: 0x2c1663), Teinte(gauche: 0x4a4f5a, droite: 0x2a2c32))
    }
    static var appStore: Teinte {      // passe par l'App Store
        choix(Teinte(gauche: 0x1d6496, droite: 0x0f3157), Teinte(gauche: 0x8a3a8c, droite: 0x3d1442), Teinte(gauche: 0x3c4a58, droite: 0x22292f))
    }
    static var manuel: Teinte {        // une étape reste à faire
        choix(Teinte(gauche: 0x47407f, droite: 0x201c45), Teinte(gauche: 0x4f3d8f, droite: 0x221a4a), Teinte(gauche: 0x48444f, droite: 0x29272d))
    }
    static var neutre: Teinte {        // onglet ou filtre non choisi, bouton secondaire
        choix(Teinte(gauche: 0x1c2756, droite: 0x0c1331), Teinte(gauche: 0x2a1c4e, droite: 0x150d2c), Teinte(gauche: 0x252528, droite: 0x1b1b1d))
    }
    static let danger = Teinte(gauche: 0x7a2340, droite: 0x351027)                                                                         // désinstaller

    static func teinte(_ a: Action) -> Teinte {
        switch a {
        case .brew, .installer: mettreAJour
        case .appStore: appStore
        default: manuel
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255, blue: Double(hex & 0xff) / 255)
    }
}

struct FondTheme: View {
    var body: some View {
        ZStack {
            T.fond
            RadialGradient(colors: [T.accent.opacity(0.30 * T.halos), .clear], center: UnitPoint(x: 0, y: -0.06), startRadius: 0, endRadius: 560)
            RadialGradient(colors: [T.rose.opacity(0.22 * T.halos), .clear], center: UnitPoint(x: 1, y: 0.02), startRadius: 0, endRadius: 480)
            RadialGradient(colors: [T.cyan.opacity(0.14 * T.halos), .clear], center: UnitPoint(x: 0.5, y: 1.12), startRadius: 0, endRadius: 700)
        }
        .ignoresSafeArea()
    }
}

struct Verre: ViewModifier {
    var rayon: CGFloat = 12
    func body(content: Content) -> some View {
        content
            .background(
                LinearGradient(colors: [T.accent.opacity(0.12), T.accent.opacity(0.05), .white.opacity(0.02)],
                               startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: rayon))
            .overlay(RoundedRectangle(cornerRadius: rayon).stroke(T.trait))
    }
}

extension View {
    func verre(_ rayon: CGFloat = 12) -> some View { modifier(Verre(rayon: rayon)) }
}

/// Tous les boutons de l'app : dégradé sombre à 90°, liseré clair, ombre douce ; appuyé, il fonce et s'enfonce.
struct BoutonPlein: ButtonStyle {
    var teinte: Teinte
    var texte: Color = .white.opacity(0.95)
    var graisse: Font.Weight = .semibold
    func makeBody(configuration: Configuration) -> some View {
        let appuye = configuration.isPressed
        return configuration.label
            .font(T.police(12, graisse))
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(texte)
            .padding(.horizontal, 14).padding(.vertical, 6)
            .background(
                Capsule().fill(LinearGradient(colors: [Color(hex: teinte.gauche), Color(hex: teinte.droite)],
                                              startPoint: .leading, endPoint: .trailing))
                    .brightness(appuye ? -0.08 : 0)
            )
            .overlay(
                Capsule().strokeBorder(LinearGradient(colors: [.white.opacity(0.28), .white.opacity(0.04)],
                                                      startPoint: .top, endPoint: .bottom), lineWidth: 1)
            )
            .shadow(color: Color(hex: teinte.droite).opacity(0.55), radius: appuye ? 2 : 6, y: appuye ? 1 : 3)
            .scaleEffect(appuye ? 0.97 : 1)
            .offset(y: appuye ? 1 : 0)
    }
}

/// Bouton secondaire (vérifier, annuler, liste complète) : même dessin, teinte neutre.
struct BoutonDiscret: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        BoutonPlein(teinte: Boutons.neutre, texte: T.texte, graisse: .medium).makeBody(configuration: configuration)
    }
}

/// Onglet ou filtre : la teinte principale quand il est choisi, la neutre sinon.
struct Puce: ButtonStyle {
    let active: Bool
    func makeBody(configuration: Configuration) -> some View {
        BoutonPlein(teinte: active ? Boutons.mettreAJour : Boutons.neutre,
                    texte: active ? .white.opacity(0.95) : T.doux,
                    graisse: active ? .semibold : .medium).makeBody(configuration: configuration)
    }
}

/// Case à cocher dessinée : carré arrondi neutre, rempli du dégradé principal quand elle est cochée.
/// `partielle` affiche un tiret (une partie seulement des apps est cochée).
struct CaseACocher: View {
    let cochee: Bool
    var partielle = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(LinearGradient(colors: [Color(hex: teinte.gauche), Color(hex: teinte.droite)],
                                         startPoint: .leading, endPoint: .trailing))
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(remplie ? .white.opacity(0.30) : T.accent.opacity(0.45), lineWidth: 1)
                if remplie {
                    Image(systemName: partielle && !cochee ? "minus" : "checkmark")
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundStyle(.white)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(width: 18, height: 18)
            .shadow(color: remplie ? Color(hex: teinte.droite).opacity(0.6) : .clear, radius: 4, y: 2)
            .contentShape(Rectangle())
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: remplie)
        }
        .buttonStyle(.plain)
    }

    private var remplie: Bool { cochee || partielle }
    private var teinte: Teinte { remplie ? Boutons.mettreAJour : Boutons.neutre }
}

/// Barre de progression : rail sombre, remplissage au dégradé des boutons (90°), liseré clair.
struct BarreProgression: View {
    let valeur: Double

    var body: some View {
        let t = Boutons.mettreAJour
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(LinearGradient(colors: [Color(hex: Boutons.neutre.gauche), Color(hex: Boutons.neutre.droite)],
                                              startPoint: .leading, endPoint: .trailing))
                Capsule()
                    .fill(LinearGradient(colors: [Color(hex: t.droite), Color(hex: t.gauche)], startPoint: .leading, endPoint: .trailing))
                    .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
                    .frame(width: max(10, g.size.width * min(1, max(0, valeur))))
                    .shadow(color: Color(hex: t.gauche).opacity(0.5), radius: 4)
            }
        }
        .frame(height: 10)
        .overlay(Capsule().strokeBorder(T.accent.opacity(0.30), lineWidth: 0.5))
        .animation(.linear(duration: 0.25), value: valeur)
    }
}

/// Interrupteur des Réglages : petit, au dégradé du thème quand il est allumé, sombre quand il est éteint.
struct Interrupteur: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        let t = configuration.isOn ? Boutons.mettreAJour : Boutons.neutre
        return Capsule()
            .fill(LinearGradient(colors: [Color(hex: t.gauche), Color(hex: t.droite)], startPoint: .leading, endPoint: .trailing))
            .overlay(Capsule().strokeBorder(.white.opacity(configuration.isOn ? 0.25 : 0.12), lineWidth: 0.5))
            .frame(width: 28, height: 16)
            .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                Circle()
                    .fill(.white.opacity(configuration.isOn ? 0.95 : 0.55))
                    .frame(width: 12, height: 12)
                    .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
                    .padding(2)
            }
            .contentShape(Capsule())
            .onTapGesture { withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) { configuration.isOn.toggle() } }
    }
}
