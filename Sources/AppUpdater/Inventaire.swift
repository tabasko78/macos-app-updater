import Foundation

/// Inventaire des applications installées : /Applications, un niveau de sous-dossiers, et ~/Applications.
enum Inventaire {
    static func scanner() -> [AppInstallee] {
        let fm = FileManager.default
        var chemins: [String] = []
        for d in ["/Applications", NSHomeDirectory() + "/Applications"] {
            guard let items = try? fm.contentsOfDirectory(atPath: d) else { continue }
            for i in items where !i.hasPrefix(".") {
                let p = d + "/" + i
                if i.hasSuffix(".app") {
                    chemins.append(p)
                } else if let sous = try? fm.contentsOfDirectory(atPath: p) {
                    chemins += sous.filter { $0.hasSuffix(".app") && !$0.hasPrefix(".") }.map { p + "/" + $0 }
                }
            }
        }
        return chemins.compactMap(lire)
    }

    static func lire(chemin: String) -> AppInstallee? {
        let fm = FileManager.default
        // Les apps iPhone installées depuis le Mac App Store rangent leur Info.plist ailleurs.
        let plist = [chemin + "/Contents/Info.plist", chemin + "/WrappedBundle/Info.plist"].first { fm.fileExists(atPath: $0) }
        guard let plist, let info = NSDictionary(contentsOfFile: plist) as? [String: Any] else { return nil }
        let bundleId = info["CFBundleIdentifier"] as? String ?? ""
        if bundleId.hasPrefix("com.apple.") || bundleId == Dossiers.id { return nil }

        let mas = fm.fileExists(atPath: chemin + "/Contents/_MASReceipt/receipt")
            || fm.fileExists(atPath: chemin + "/Wrapper/iTunesMetadata.plist")
        return AppInstallee(
            chemin: chemin,
            nom: ((chemin as NSString).lastPathComponent as NSString).deletingPathExtension,
            bundleId: bundleId,
            version: (info["CFBundleShortVersionString"] as? String ?? "").trimmingCharacters(in: .whitespaces),
            build: (info["CFBundleVersion"] as? String ?? "").trimmingCharacters(in: .whitespaces),
            feedSparkle: (info["SUFeedURL"] as? String).flatMap { URL(string: $0.trimmingCharacters(in: .whitespaces)) },
            mas: mas
        )
    }
}
