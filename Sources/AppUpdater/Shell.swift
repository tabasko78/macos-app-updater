import Foundation

enum Shell {
    /// Lance un programme, renvoie son code de sortie et sa sortie complète ; `ligne` reçoit la sortie au fil de l'eau.
    static func lancer(_ exe: String, _ args: [String], env extra: [String: String] = [:], delai: TimeInterval? = nil, ligne: (@Sendable (String) -> Void)? = nil) async -> (code: Int32, sortie: String) {
        await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = args
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            env["HOMEBREW_NO_COLOR"] = "1"
            env["HOMEBREW_NO_EMOJI"] = "1"
            env["HOMEBREW_NO_ENV_HINTS"] = "1"
            for (k, v) in extra { env[k] = v }
            p.environment = env
            let tuyau = Pipe()
            p.standardOutput = tuyau
            p.standardError = tuyau
            p.standardInput = FileHandle.nullDevice
            let tampon = Tampon()
            tuyau.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                guard !d.isEmpty, let s = String(data: d, encoding: .utf8) else { return }
                tampon.ajouter(s)
                ligne?(s)
            }
            p.terminationHandler = { pr in
                tuyau.fileHandleForReading.readabilityHandler = nil
                let reste = tuyau.fileHandleForReading.readDataToEndOfFile()
                if let s = String(data: reste, encoding: .utf8), !s.isEmpty {
                    tampon.ajouter(s)
                    ligne?(s)
                }
                cont.resume(returning: (pr.terminationStatus, tampon.texte))
            }
            do { try p.run() } catch { cont.resume(returning: (-1, error.localizedDescription)); return }
            // Garde-fou : un appel qui attend une fenêtre restée cachée ne bloque pas l'app indéfiniment.
            if let delai {
                DispatchQueue.global().asyncAfter(deadline: .now() + delai) { if p.isRunning { p.terminate() } }
            }
        }
    }
}

final class Tampon: @unchecked Sendable {
    private let verrou = NSLock()
    private var t = ""
    func ajouter(_ s: String) { verrou.lock(); t += s; verrou.unlock() }
    var texte: String { verrou.lock(); defer { verrou.unlock() }; return t }
}
