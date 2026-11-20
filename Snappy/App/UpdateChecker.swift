import AppKit

/// Checks GitHub Releases for a newer Snappy version and installs it on
/// request. When the app was installed via Homebrew (`brew install --cask`),
/// the update goes through `brew upgrade --cask snappy`; otherwise the
/// release DMG is downloaded, mounted, and copied over the running app.
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    @Published private(set) var isWorking = false

    private let latestReleaseURL = URL(
        string: "https://api.github.com/repos/psybers/snappy/releases/latest"
    )!

    private struct LatestRelease: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
        }
        let tag_name: String
        let body: String?
        let assets: [Asset]
    }

    struct UpdateError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// `manual` controls whether failures and "up to date" are shown; automatic
    /// launch checks stay silent unless an update is found.
    func checkForUpdates(manual: Bool = false) async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }

        do {
            let release = try await fetchLatestRelease()
            let latest = release.tag_name
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "^v", with: "", options: .regularExpression)
            guard Self.isNewer(latest, than: currentVersion) else {
                if manual {
                    showAlert("You're up to date", "Snappy \(currentVersion) is the latest version.")
                }
                return
            }
            guard confirmUpdate(to: latest, notes: release.body) else { return }
            try await installLatest(release: release)
            promptRestart(version: latest)
        } catch {
            if manual {
                showAlert("Update check failed", error.localizedDescription)
            }
        }
    }

    /// Compares dotted numeric versions ("0.4.1" > "0.4.0", "0.10.0" > "0.9.9").
    /// Non-numeric suffixes are ignored per component.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ version: String) -> [Int] {
            version.split(separator: ".").map { component in
                Int(component.prefix { $0.isNumber }) ?? 0
            }
        }
        let candidateParts = parts(candidate)
        let currentParts = parts(current)
        for index in 0..<max(candidateParts.count, currentParts.count) {
            let lhs = index < candidateParts.count ? candidateParts[index] : 0
            let rhs = index < currentParts.count ? currentParts[index] : 0
            if lhs != rhs { return lhs > rhs }
        }
        return false
    }

    private var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    private func fetchLatestRelease() async throws -> LatestRelease {
        var request = URLRequest(url: latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode)
        else {
            throw UpdateError(message: "GitHub returned an unexpected response.")
        }
        return try JSONDecoder().decode(LatestRelease.self, from: data)
    }

    private func confirmUpdate(to version: String, notes: String?) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Snappy \(version) is available"
        var informative = "You are running Snappy \(currentVersion)."
        if let notes = notes?.trimmingCharacters(in: .whitespacesAndNewlines),
           !notes.isEmpty {
            informative += "\n\n\(String(notes.prefix(1200)))"
        }
        alert.informativeText = informative
        alert.addButton(withTitle: "Download Update")
        alert.addButton(withTitle: "Later")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func installLatest(release: LatestRelease) async throws {
        if brewCaskInstalled, let brew = brewExecutable {
            _ = try await run(brew, ["upgrade", "--cask", "snappy"])
            try await removeQuarantine(from: Bundle.main.bundleURL)
            return
        }

        guard let dmg = release.assets.first(where: { $0.name.hasSuffix(".dmg") }) else {
            throw UpdateError(message: "The latest release has no DMG download.")
        }
        let (downloaded, _) = try await URLSession.shared.download(from: dmg.browser_download_url)
        let mountPoint = "/tmp/snappy-update-\(UUID().uuidString)"
        _ = try await run("/usr/bin/hdiutil", [
            "attach", "-nobrowse", "-readonly", "-mountpoint", mountPoint, downloaded.path
        ])
        let destination = Bundle.main.bundleURL
        do {
            let sourceApp = URL(fileURLWithPath: mountPoint).appendingPathComponent("Snappy.app")
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            _ = try await run("/usr/bin/ditto", [sourceApp.path, destination.path])
            try await removeQuarantine(from: destination)
        } catch {
            _ = try? await run("/usr/bin/hdiutil", ["detach", mountPoint])
            throw error
        }
        _ = try? await run("/usr/bin/hdiutil", ["detach", mountPoint])
    }

    private var brewExecutable: String? {
        for path in ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"] {
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    /// Homebrew installs casks under $PREFIX/Caskroom/<cask>/<version>.
    private var brewCaskInstalled: Bool {
        let fileManager = FileManager.default
        return fileManager.fileExists(atPath: "/opt/homebrew/Caskroom/snappy")
            || fileManager.fileExists(atPath: "/usr/local/Caskroom/snappy")
    }

    private func removeQuarantine(from appURL: URL) async throws {
        _ = try await run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", appURL.path])
    }

    /// Relaunching must wait for this process to exit, so a detached shell
    /// sleeps briefly and then opens the (already replaced) app bundle.
    private func promptRestart(version: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Update installed"
        alert.informativeText = "Restart Snappy now to start using version \(version)?"
        alert.addButton(withTitle: "Restart")
        alert.addButton(withTitle: "Later")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let script = "sleep 1; open \(Self.shellQuoted(Bundle.main.bundleURL.path))"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        try? process.run()
        NSApp.terminate(nil)
    }

    private func showAlert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Runs a command to completion and returns its combined output. Output
    /// goes to a file rather than a pipe: a chatty command like
    /// `brew upgrade` could otherwise block on a full pipe buffer.
    private func run(_ executable: String, _ arguments: [String]) async throws -> String {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("snappy-update-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: outputURL) }

        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            let handle = try? FileHandle(forWritingTo: outputURL)
            process.standardOutput = handle
            process.standardError = handle
            process.terminationHandler = { process in
                try? handle?.close()
                let output = (try? String(contentsOf: outputURL, encoding: .utf8)) ?? ""
                let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
                if process.terminationStatus == 0 {
                    continuation.resume(returning: output)
                } else {
                    continuation.resume(
                        throwing: UpdateError(
                            message: "\(executable) failed (\(process.terminationStatus)): \(trimmed)"
                        )
                    )
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
