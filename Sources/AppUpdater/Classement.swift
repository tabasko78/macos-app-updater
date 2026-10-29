import Foundation

/// Ce qu'est une app qu'aucune source ne suit : elle n'est pas « sans source », elle a une raison.
enum Classement: String, CaseIterable, Identifiable, Sendable {
    case composant = "Composant"      // fait partie d'une autre app, se met à jour avec elle
    case integree = "Intégrée"        // a son propre système de mise à jour, illisible de l'extérieur
    case abandonnee = "Abandonnée"    // plus aucune version ne sortira
    case perso = "Perso"              // une app à soi

    var id: String { rawValue }
    var libelle: String { source.libelle }
    var source: Source {
        switch self {
        case .composant: .composant
        case .integree: .integree
        case .abandonnee: .abandonnee
        case .perso: .perso
        }
    }
    var explication: String {
        switch self {
        case .composant: L.t("se met à jour avec l'app dont elle fait partie", "updated together with the app it belongs to")
        case .integree: L.t("se met à jour toute seule, par son propre système", "updates itself, with its own updater")
        case .abandonnee: L.t("plus aucune version ne sortira", "no new version will ever come out")
        case .perso: L.t("app personnelle", "personal app")
        }
    }
}

enum Classeur {
    /// Cas connus : identifiant (ou début d'identifiant) → classement et raison.
    private static var connus: [(String, Classement, String)] { [
        ("com.adobe.", .integree, L.t("se met à jour par Creative Cloud", "updated by Creative Cloud")),
        ("com.bitdefender.", .integree, L.t("se met à jour par Bitdefender", "updated by Bitdefender")),
        ("net.downloadhelper.coapp", .composant, L.t("compagnon de l'extension Video DownloadHelper de Firefox", "companion of the Video DownloadHelper Firefox extension")),
        ("com.anthropic.claude-code-url-handler", .composant, L.t("composant de Claude Code", "part of Claude Code")),
        ("com.lihaoyun6.PD-Runner", .abandonnee, L.t("dépôt GitHub bloqué depuis 2022", "GitHub repository blocked since 2022")),
        ("com.yourcompany.PairingWizard", .abandonnee, L.t("utilitaire sans éditeur identifiable", "utility with no identifiable developer")),
    ] }

    /// `ids` : bundle id → nom de toutes les apps installées, pour reconnaître les composants.
    static func classer(_ a: AppInstallee, ids: [String: String]) -> (Classement, String)? {
        if ConfigApp.appsPerso.contains(a.nom) { return (.perso, L.t("app personnelle", "personal app")) }
        if let c = connus.first(where: { a.bundleId == $0.0 || ($0.0.hasSuffix(".") && a.bundleId.hasPrefix($0.0)) }) {
            return (c.1, c.2)
        }
        let n = a.nom.lowercased()
        if n.hasPrefix("uninstall") || n.contains("uninstaller") || n.hasSuffix("installer") {
            return (.composant, L.t("installeur ou désinstalleur livré avec une autre app", "installer or uninstaller shipped with another app"))
        }
        // com.google.drivefs.shortcuts.docs commence par com.google.drivefs, qui est Google Drive
        if let (id, nom) = ids.first(where: { $0.key != a.bundleId && a.bundleId.hasPrefix($0.key + ".") }) {
            _ = id
            return (.composant, L.t("fait partie de \(nom)", "part of \(nom)"))
        }
        // org.freefilesync.RealTimeSync : même éditeur (org.freefilesync) que FreeFileSync
        let editeur = a.bundleId.split(separator: ".").prefix(2).joined(separator: ".")
        if editeur.contains("."), let (_, nom) = ids.first(where: { $0.key != a.bundleId && $0.key.hasPrefix(editeur + ".") }) {
            return (.composant, L.t("livrée avec \(nom)", "shipped with \(nom)"))
        }
        if a.mas { return (.abandonnee, L.t("retirée de l'App Store", "removed from the App Store")) }
        if a.cask != nil { return (.integree, L.t("se met à jour toute seule, Homebrew ne publie pas de numéro de version", "updates itself; Homebrew publishes no version number")) }
        return nil
    }
}
