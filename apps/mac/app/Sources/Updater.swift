// Updating the app itself from the newest release.

import AppKit

extension Model {
    /// Each release (vX.Y.Z) carries version.txt with its version. A newer one than this app's
    /// means an update: download that release's zip, swap this app's bundle for it once the app
    /// has quit, and open it again.
    static let release = "https://github.com/jonathanrobichaud4/EngineOS-Emulator/releases/latest/download/"

    /// True if version a (like 1.2.10) is newer than b.
    static func newer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    func checkAppUpdate(manual: Bool) {
        guard BuildInfo.version != "dev" else {
            if manual { append("This is a test build (not from a release), so it doesn't update itself.\n") }
            return
        }
        var req = URLRequest(url: URL(string: Model.release + "version.txt")!)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession.shared.dataTask(with: req) { data, resp, err in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let latest = data.map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
            DispatchQueue.main.async {
                guard code == 200, latest.first?.isNumber == true else {
                    self.append("Couldn't check for app updates\(err.map { ": \($0.localizedDescription)" } ?? " (HTTP \(code))").\n")
                    return
                }
                let d = UserDefaults.standard
                if !Model.newer(latest, than: BuildInfo.version) {
                    d.removeObject(forKey: "updateAttempt")
                    self.append("The app is up to date (v\(BuildInfo.version)).\n")
                    return
                }
                // Already tried this build and it's still not running: the swap failed. Don't
                // loop; say why and leave it to "Check for app updates" or a manual download.
                if !manual, d.string(forKey: "updateAttempt") == latest {
                    let log = (try? String(contentsOf: AppInfo.updateLog, encoding: .utf8)) ?? ""
                    self.append("The update to v\(latest) didn't install last time.\n" + log +
                        "If macOS blocked it, allow \(AppInfo.name) under System Settings > Privacy & Security > App Management, " +
                        "then use Check for app updates in Settings. Or download it from the release page.\n")
                    return
                }
                self.installAppUpdate(latest)
            }
        }.resume()
    }

    private func installAppUpdate(_ latest: String) {
        append("\n> Downloading \(AppInfo.name) v\(latest)\n")
        var req = URLRequest(url: URL(string: Model.release + AppInfo.zip)!)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession.shared.downloadTask(with: req) { tmp, resp, err in
            let fail = { (why: String) in DispatchQueue.main.async { self.append("App update failed: \(why)\n") } }
            guard let tmp = tmp, (resp as? HTTPURLResponse)?.statusCode == 200 else { fail(err?.localizedDescription ?? "download failed"); return }
            let fm = FileManager.default
            let work = fm.temporaryDirectory.appendingPathComponent("engineos-update-\(UUID().uuidString)")
            do {
                try fm.createDirectory(at: work, withIntermediateDirectories: true)
                let zip = work.appendingPathComponent("app.zip")
                try fm.moveItem(at: tmp, to: zip)
                let unzip = Process()
                unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                unzip.arguments = ["-x", "-k", zip.path, work.path]
                try unzip.run(); unzip.waitUntilExit()
                guard unzip.terminationStatus == 0,
                      let newApp = try fm.contentsOfDirectory(at: work, includingPropertiesForKeys: nil).first(where: { $0.pathExtension == "app" })
                else { fail("the download didn't contain the app"); return }
                // Where the app really is. An app opened straight from Downloads runs from a
                // read-only copy macOS makes ("App Translocation"); the original is what to replace.
                let old = AppInfo.originalBundleURL()
                var folder = old.deletingLastPathComponent()
                var replace = true
                if !fm.isWritableFile(atPath: folder.path) {
                    // Can't touch the original: put the new app in Applications instead.
                    let apps = URL(fileURLWithPath: "/Applications")
                    let mine = fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
                    if fm.isWritableFile(atPath: apps.path) { folder = apps }
                    else { try? fm.createDirectory(at: mine, withIntermediateDirectories: true); folder = mine }
                    replace = false
                }
                // Swap the bundles after this app quits, then open the new one. It goes in under
                // its own name, so an install from before the rename picks up the new name.
                let dest = folder.appendingPathComponent(newApp.lastPathComponent)
                let script = work.appendingPathComponent("swap.sh")
                let q = { (u: URL) in "'" + u.path.replacingOccurrences(of: "'", with: "'\\''") + "'" }
                let (o, n, t) = (q(old), q(newApp), q(dest))
                // Writes what happened to update.log, and never deletes the old app unless the new
                // one is in place: on any failure the old one is put back and opened.
                let sh = """
                #!/bin/bash
                mkdir -p \(q(AppInfo.updateLog.deletingLastPathComponent())); exec >\(q(AppInfo.updateLog)) 2>&1
                echo "Update to v\(latest), $(date)"
                while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done
                ok=
                if \(replace ? "true" : "false"); then
                  rm -rf \(o).old
                  if mv \(o) \(o).old && mv \(n) \(t); then ok=1
                  else echo "Couldn't replace \(old.path)."; [ -e \(o) ] || mv \(o).old \(o); fi
                else
                  rm -rf \(t); mv \(n) \(t) && ok=1
                fi
                if [ -n "$ok" ]; then
                  # Without the quarantine flag macOS runs it in place from now on (no translocation).
                  xattr -dr com.apple.quarantine \(t) 2>/dev/null
                  rm -rf \(o).old
                  echo "Installed \(dest.path)."
                  open \(t)
                else
                  open \(o)
                fi
                """
                try sh.write(to: script, atomically: true, encoding: .utf8)
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/bash")
                p.arguments = [script.path]
                try p.run()
                DispatchQueue.main.async {
                    if !replace { self.append("Installed the new app in \(folder.path) (couldn't replace the copy in \(old.deletingLastPathComponent().path)). You can delete the old one.\n") }
                    self.updating = true
                    UserDefaults.standard.set(latest, forKey: "updateAttempt")
                    self.append("Restarting with the new app...\n")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { NSApp.terminate(nil) }
                }
            } catch {
                fail(error.localizedDescription)
            }
        }.resume()
    }
}
