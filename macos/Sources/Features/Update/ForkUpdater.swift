import Cocoa
import OSLog

/// Fork-only replacement for the Sparkle updater.
///
/// Instead of downloading official builds, "Check for Updates" merges
/// upstream `main` into this fork's checkout, rebuilds it, and swaps the
/// installed app. The real work lives in `fork/update.sh`; this class just
/// drives it and shows alerts. The build output streams into a terminal
/// window running `tail -f` on the log so you can watch it.
class ForkUpdater {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier!,
        category: "ForkUpdater")

    /// UserDefaults key holding the path to the fork's source checkout.
    /// `fork/update.sh install` keeps this up to date.
    private static let repoPathKey = "ForkRepoPath"

    private static let logURL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/ghostty-fork-update.log")

    private enum Phase {
        case idle
        case checking
        case building
        case readyToInstall
        case restarting
    }

    private var phase: Phase = .idle
    private weak var logWindow: TerminalController?

    /// True once the user chose to restart into a new build, so quitting
    /// shouldn't ask for confirmation.
    var isRestartingForUpdate: Bool { phase == .restarting }

    func checkForUpdates() {
        switch phase {
        case .idle:
            break
        case .checking, .restarting:
            return
        case .building:
            logWindow?.window?.makeKeyAndOrderFront(nil)
            return
        case .readyToInstall:
            promptRestart()
            return
        }

        guard let script = scriptURL() else { return }

        phase = .checking
        run(script, ["check"]) { [weak self] status, output in
            guard let self else { return }
            self.phase = .idle
            guard status == 0 else {
                self.showError("Couldn't check for updates", output)
                return
            }
            self.handleCheckResult(script, output)
        }
    }

    // MARK: Steps

    private func handleCheckResult(_ script: URL, _ output: String) {
        let parts = output.components(separatedBy: "\n---\n")
        var values: [String: String] = [:]
        for line in parts[0].split(separator: "\n") {
            let kv = line.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { values[kv[0]] = kv[1] }
        }
        let subjects = parts.count > 1
            ? parts[1].split(separator: "\n").map(String.init)
            : []

        let upstreamCount = Int(values["upstream_count"] ?? "") ?? 0
        let totalCount = Int(values["total_count"] ?? "") ?? 0
        let installed = String((values["installed"] ?? "").prefix(9))

        let alert = NSAlert()
        guard totalCount > 0 else {
            alert.messageText = "You're Up to Date"
            alert.informativeText = "Your fork already includes the latest upstream main (built from \(installed))."
            alert.runModal()
            return
        }

        alert.messageText = upstreamCount == 1
            ? "1 New Upstream Commit"
            : "\(upstreamCount) New Upstream Commits"
        var info = subjects.map { "• \($0)" }.joined(separator: "\n")
        if upstreamCount > subjects.count {
            info += "\n…and \(upstreamCount - subjects.count) more"
        }
        if totalCount > upstreamCount {
            info += "\n\nYour fork also has \(totalCount - upstreamCount) commit(s) not in this build."
        }
        info += "\n\nUpdating merges upstream into your fork's main, pushes it, and rebuilds Ghostty. The build takes a few minutes."
        alert.informativeText = info
        alert.addButton(withTitle: "Update and Rebuild")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        startBuild(script)
    }

    private func startBuild(_ script: URL) {
        phase = .building
        try? Data().write(to: Self.logURL)
        openLogWindow()

        run(script, ["build"], logTo: Self.logURL) { [weak self] status, _ in
            guard let self else { return }
            guard status == 0 else {
                self.phase = .idle
                self.showError(
                    "Update Failed",
                    "See the log window for details. The log is also saved at \(Self.logURL.path).")
                return
            }

            self.phase = .readyToInstall
            self.logWindow?.closeWindowImmediately()
            self.promptRestart()
        }
    }

    private func promptRestart() {
        let alert = NSAlert()
        alert.messageText = "Update Ready"
        alert.informativeText = "The new build is ready. Restart Ghostty to install it?"
        alert.addButton(withTitle: "Restart Now")
        alert.addButton(withTitle: "Later")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let script = scriptURL() else { return }

        // The install step waits for us to exit, so it must outlive us. Process
        // children aren't killed when the parent app terminates.
        let args = [
            "install",
            "--wait-pid", String(ProcessInfo.processInfo.processIdentifier),
            "--app", Bundle.main.bundlePath,
            "--defaults-domain", Bundle.main.bundleIdentifier ?? "com.mitchellh.ghostty",
        ]
        do {
            _ = try launch(script, args, logTo: Self.logURL, append: true)
        } catch {
            showError("Couldn't start the installer", error.localizedDescription)
            return
        }

        phase = .restarting
        NSApp.terminate(nil)
    }

    // MARK: Helpers

    /// Locate `fork/update.sh`, asking for the checkout the first time.
    private func scriptURL() -> URL? {
        if let path = UserDefaults.ghostty.string(forKey: Self.repoPathKey),
           let url = Self.script(inRepo: URL(fileURLWithPath: path)) {
            return url
        }

        let panel = NSOpenPanel()
        panel.message = "Choose your Ghostty fork's source checkout"
        panel.prompt = "Choose"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let repo = panel.url else { return nil }

        guard let url = Self.script(inRepo: repo) else {
            showError(
                "Not a Ghostty Fork Checkout",
                "\(repo.path) doesn't contain fork/update.sh.")
            return nil
        }
        UserDefaults.ghostty.set(repo.path, forKey: Self.repoPathKey)
        return url
    }

    private static func script(inRepo repo: URL) -> URL? {
        let url = repo.appendingPathComponent("fork/update.sh")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    private func openLogWindow() {
        guard let appDelegate = NSApp.delegate as? AppDelegate else { return }
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/usr/bin/tail -n +1 -f '\(Self.logURL.path)'"
        logWindow = TerminalController.newWindow(appDelegate.ghostty, withBaseConfig: config)
    }

    /// Run the script and call `completion` on the main queue with its exit
    /// status and combined output. With `logTo`, output goes to that file
    /// instead and `completion` gets an empty string.
    private func run(
        _ script: URL,
        _ args: [String],
        logTo log: URL? = nil,
        completion: @escaping (Int32, String) -> Void
    ) {
        let pipe = Pipe()
        let process: Process
        do {
            process = try launch(script, args, logTo: log, pipe: log == nil ? pipe : nil)
        } catch {
            phase = .idle
            showError("Couldn't run \(script.path)", error.localizedDescription)
            return
        }
        Self.logger.info("started fork/update.sh \(args.first ?? "") pid=\(process.processIdentifier)")

        // Drain the pipe until EOF before waiting so a chatty script can't
        // block on a full pipe buffer.
        DispatchQueue.global(qos: .userInitiated).async {
            let data = log == nil ? pipe.fileHandleForReading.readDataToEndOfFile() : Data()
            process.waitUntilExit()
            let output = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async {
                completion(process.terminationStatus, output)
            }
        }
    }

    @discardableResult
    private func launch(
        _ script: URL,
        _ args: [String],
        logTo log: URL? = nil,
        append: Bool = false,
        pipe: Pipe? = nil
    ) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path] + args
        process.currentDirectoryURL = script.deletingLastPathComponent().deletingLastPathComponent()
        process.standardInput = FileHandle.nullDevice

        var logHandle: FileHandle?
        if let log {
            if !FileManager.default.fileExists(atPath: log.path) {
                FileManager.default.createFile(atPath: log.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: log)
            if append { try handle.seekToEnd() }
            logHandle = handle
            process.standardOutput = handle
            process.standardError = handle
        } else if let pipe {
            process.standardOutput = pipe
            process.standardError = pipe
        }

        try process.run()

        // The child has its own copy of the descriptor now.
        try? logHandle?.close()
        return process
    }

    private func showError(_ title: String, _ detail: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        alert.runModal()
    }
}
