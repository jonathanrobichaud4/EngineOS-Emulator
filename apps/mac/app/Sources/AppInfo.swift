// The app's name, in one place, and what carries over from before the rename (SC LIVE 4
// Emulator): its settings, and its drive folder until the launcher moves it.

import AppKit

enum AppInfo {
    static let name = "EngineOS Emulator"
    static let zip = "EngineOSEmulator-mac.zip"
    static let script = "engineos-emu"

    /// ~/EngineOSEmulator, or ~/SCLive4Emulator on an older install whose VM hasn't restarted
    /// since (engineos-emu moves it then).
    static var share: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let new = home.appendingPathComponent("EngineOSEmulator"), old = home.appendingPathComponent("SCLive4Emulator")
        let fm = FileManager.default
        return !fm.fileExists(atPath: new.path) && fm.fileExists(atPath: old.path) ? old : new
    }

    /// Settings saved under the old bundle id, copied over once.
    private static let migrated: Void = {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "migratedFromSCLive4"),
              let old = UserDefaults(suiteName: "io.github.jonathanrobichaud4.sclive4-emulator") else { return }
        for k in ["autoStart", "openDeck", "autoUpdate", "softwareRender", "autoUpdateApp", "deck"]
            where d.object(forKey: k) == nil {
            if let v = old.object(forKey: k) { d.set(v, forKey: k) }
        }
        d.set(true, forKey: "migratedFromSCLive4")
    }()

    /// The app bundle's real location, even when macOS is running it from a translocated copy.
    static func originalBundleURL() -> URL {
        let here = Bundle.main.bundleURL
        guard here.path.contains("/AppTranslocation/"),
              let lib = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_NOW),
              let sym = dlsym(lib, "SecTranslocateCreateOriginalPathForURL") else { return here }
        typealias F = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
        let f = unsafeBitCast(sym, to: F.self)
        return f(here as CFURL, nil)?.takeRetainedValue() as URL? ?? here
    }

    static var updateLog: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/\(name)/update.log")
    }

    static func savedDeck() -> String {
        _ = migrated
        return UserDefaults.standard.string(forKey: "deck") ?? "default"
    }
}
