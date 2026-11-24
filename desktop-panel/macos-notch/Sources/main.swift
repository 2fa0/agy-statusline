import AppKit
import Foundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: NotchStore!
    private var manager: NotchWindowManager!
    private var terminateObserver: NSObjectProtocol?
    private var lifecycleTimer: Timer?
    private var sawAntigravityRunning = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGPIPE, SIG_IGN)
        let args = CommandLine.arguments
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let exeDir = URL(fileURLWithPath: args[0]).deletingLastPathComponent().path

        var backendPath = "\(exeDir)/agy-desktop-backend"
        if !FileManager.default.isExecutableFile(atPath: backendPath) {
            backendPath = "\(home)/.gemini/antigravity/plugins/agy-desktop-status/sidecars/status/agy-desktop-backend"
        }
        var dataDir = ProcessInfo.processInfo.environment["PLUGIN_DATA"]
            ?? "\(home)/.gemini/antigravity/plugin_data/agy-desktop-status"
        var demoMode = false
        var isCLI = false
        var dataRoot: String?

        var idx = 1
        while idx < args.count {
            let arg = args[idx]
            if arg == "--demo" {
                demoMode = true
            } else if arg == "--cli" {
                isCLI = true
            } else if arg == "--desktop-root", idx + 1 < args.count {
                idx += 1
                dataRoot = args[idx]
            } else if arg == "--backend", idx + 1 < args.count {
                idx += 1
                backendPath = args[idx]
            } else if arg == "--data-dir", idx + 1 < args.count {
                idx += 1
                dataDir = args[idx]
            }
            idx += 1
        }

        if !demoMode && !acquireSingleInstanceLock(dataDir: dataDir) {
            NSApp.terminate(nil)
            return
        }

        store = NotchStore(backendPath: backendPath, dataDir: dataDir, demoMode: demoMode, dataRoot: dataRoot, isCLI: isCLI)
        manager = NotchWindowManager(store: store)
        MenuActions.shared.store = store
        MenuActions.shared.manager = manager

        if !demoMode && !store.isCLI {
            startAntigravityLifecycleWatch()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        lifecycleTimer?.invalidate()
        if let obs = terminateObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
        store?.shutdown()
    }

    private func isAntigravityRunning() -> Bool {
        autoreleasepool {
            NSWorkspace.shared.runningApplications.contains { app in
                let name = (app.localizedName ?? "").lowercased()
                let bid = (app.bundleIdentifier ?? "").lowercased()
                return name.contains("antigravity") || bid.contains("antigravity")
            }
        }
    }

    private func startAntigravityLifecycleWatch() {
        sawAntigravityRunning = isAntigravityRunning()

        terminateObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let name = (app.localizedName ?? "").lowercased()
            let bid = (app.bundleIdentifier ?? "").lowercased()
            guard name.contains("antigravity") || bid.contains("antigravity") else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self else { return }
                if !self.isAntigravityRunning() {
                    NSApp.terminate(nil)
                }
            }
        }

        let t = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let running = self.isAntigravityRunning()
                if running {
                    self.sawAntigravityRunning = true
                } else if self.sawAntigravityRunning {
                    NSApp.terminate(nil)
                }
            }
        }
        t.tolerance = 4.0
        lifecycleTimer = t
    }

    private var lockFD: Int32 = -1
    private func acquireSingleInstanceLock(dataDir: String) -> Bool {
        try? FileManager.default.createDirectory(atPath: dataDir, withIntermediateDirectories: true)
        let lockPath = "\(dataDir)/agy-notch.lock"
        let fd = open(lockPath, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return true }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            return false
        }
        lockFD = fd
        return true
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
