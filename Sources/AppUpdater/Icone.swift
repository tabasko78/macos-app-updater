import AppKit

/// L'icône de l'app, dessinée aux couleurs du thème : fond sombre à halos, anneau de rafraîchissement, flèche.
/// Le Dock la reprend à chaque changement de thème ; `construire.sh` en tire le fichier .icns du paquet.
enum Icone {
    static func image(_ theme: ThemeNom) -> NSImage {
        let i = NSImage(size: NSSize(width: 1024, height: 1024))
        i.addRepresentation(rendu(theme))
        return i
    }

    static func png(_ theme: ThemeNom) -> Data? { rendu(theme).representation(using: .png, properties: [:]) }

    private static func rendu(_ theme: ThemeNom) -> NSBitmapImageRep {
        let p: Palette = switch theme {
        case .bleuNuit: T.bleuNuit
        case .violine: T.violine
        case .graphite: T.graphite
        }
        let halos: CGFloat = theme == .graphite ? 0.35 : 1
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        let g = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.current = g
        let ctx = g.cgContext

        // Fond : carré arrondi, ombre portée, dégradé du fond du thème, trois halos (accent, rose, cyan).
        let cadre = CGRect(x: 100, y: 100, width: 824, height: 824)
        let forme = CGPath(roundedRect: cadre, cornerWidth: 186, cornerHeight: 186, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 34, color: NSColor.black.withAlphaComponent(0.45).cgColor)
        ctx.addPath(forme); ctx.setFillColor(couleur(p.fond).cgColor); ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(forme); ctx.clip()
        NSGradient(colors: [eclaircir(p.fond, 0.10), couleur(p.fond)])!
            .draw(in: NSRect(x: cadre.minX, y: cadre.minY, width: cadre.width, height: cadre.height), angle: -90)
        for (hex, a, x, y, r) in [(p.accent, 0.55, 230.0, 900.0, 620.0), (p.rose, 0.40, 900.0, 820.0, 520.0), (p.cyan, 0.25, 512.0, 60.0, 560.0)] {
            let c = NSPoint(x: x, y: y)
            NSGradient(colors: [couleur(hex, a * halos), couleur(hex, 0)])!.draw(fromCenter: c, radius: 0, toCenter: c, radius: r, options: [])
        }
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(forme); ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.10).cgColor); ctx.setLineWidth(3); ctx.strokePath()
        ctx.restoreGState()

        // Anneau en flèche, du blanc vers une teinte claire de l'accent.
        anneau(ctx, couleurs: [NSColor.white, melange(p.accent, 0.72)])
        // Flèche de téléchargement au centre.
        fleche(ctx, couleur: NSColor.white)

        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    private static func anneau(_ ctx: CGContext, couleurs: [NSColor]) {
        let centre = CGPoint(x: 512, y: 512), rayon: CGFloat = 265, epaisseur: CGFloat = 64
        let debut: CGFloat = .pi * 0.62, fin: CGFloat = .pi * 2.38
        let arc = CGMutablePath()
        arc.addArc(center: centre, radius: rayon, startAngle: debut, endAngle: fin, clockwise: false)
        let trait = arc.copy(strokingWithWidth: epaisseur, lineCap: .round, lineJoin: .round, miterLimit: 10)
        let tangente = CGPoint(x: -sin(fin), y: cos(fin)), normale = CGPoint(x: cos(fin), y: sin(fin))
        let pf = CGPoint(x: centre.x + rayon * normale.x - tangente.x * epaisseur * 0.2, y: centre.y + rayon * normale.y - tangente.y * epaisseur * 0.2)
        let l = epaisseur * 1.05, av = epaisseur * 1.1
        let pointe = CGMutablePath()
        pointe.move(to: CGPoint(x: pf.x + normale.x * l, y: pf.y + normale.y * l))
        pointe.addLine(to: CGPoint(x: pf.x + tangente.x * av, y: pf.y + tangente.y * av))
        pointe.addLine(to: CGPoint(x: pf.x - normale.x * l, y: pf.y - normale.y * l))
        pointe.closeSubpath()
        let boite = NSRect(x: centre.x - rayon - epaisseur * 2, y: centre.y - rayon - epaisseur * 2,
                           width: (rayon + epaisseur * 2) * 2, height: (rayon + epaisseur * 2) * 2)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 18, color: NSColor.black.withAlphaComponent(0.35).cgColor)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        for morceau in [trait, pointe as CGPath] {   // deux passes : un seul clip des deux formes les annulait par endroits
            ctx.saveGState(); ctx.addPath(morceau); ctx.clip()
            NSGradient(colors: couleurs)!.draw(in: boite, angle: -45)
            ctx.restoreGState()
        }
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    private static func fleche(_ ctx: CGContext, couleur: NSColor) {
        let centre = CGPoint(x: 512, y: 500), taille: CGFloat = 250
        let t = taille / 2, tige = taille * 0.15, tete = taille * 0.40, haut = centre.y + t, col = centre.y - t * 0.05, bas = centre.y - t
        let p = CGMutablePath()
        p.move(to: CGPoint(x: centre.x - tige, y: haut))
        p.addLine(to: CGPoint(x: centre.x + tige, y: haut))
        p.addLine(to: CGPoint(x: centre.x + tige, y: col))
        p.addLine(to: CGPoint(x: centre.x + tete, y: col))
        p.addLine(to: CGPoint(x: centre.x, y: bas))
        p.addLine(to: CGPoint(x: centre.x - tete, y: col))
        p.addLine(to: CGPoint(x: centre.x - tige, y: col))
        p.closeSubpath()
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -5), blur: 14, color: NSColor.black.withAlphaComponent(0.35).cgColor)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)   // une seule ombre pour le remplissage et le contour
        ctx.addPath(p); ctx.setFillColor(couleur.cgColor); ctx.setStrokeColor(couleur.cgColor)
        ctx.setLineJoin(.round); ctx.setLineWidth(taille * 0.07)
        ctx.drawPath(using: .fillStroke)
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    private static func couleur(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: a)
    }

    private static func eclaircir(_ hex: UInt32, _ x: CGFloat) -> NSColor { couleur(hex).blended(withFraction: x, of: .white) ?? couleur(hex) }

    /// La couleur, mêlée de blanc à `x` (0,72 : une teinte très claire de l'accent).
    private static func melange(_ hex: UInt32, _ x: CGFloat) -> NSColor { couleur(hex).blended(withFraction: x, of: .white) ?? .white }
}
