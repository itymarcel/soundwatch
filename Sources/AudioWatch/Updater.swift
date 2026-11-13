import AppKit
import Foundation

/// Checks GitHub Releases for a newer soundwatch and replaces the app in place.
///
/// Settings and presets live in UserDefaults (~/Library/Preferences/<bundle id>.plist), outside the app bundle, so swapping
/// the bundle never touches them. A new version's built-in presets are added by `seedDefaultPresets` (per name, once), so
/// presets the user deleted stay deleted and edited ones are not overwritten.
///
/// Flow: launch (at most every 20 h) or "Check for Updates…" → GitHub API `releases/latest` → if its tag is newer than
/// CFBundleShortVersionString, ask → download the `soundwatch-*.zip` asset → unzip next to the app (same volume) → check
/// bundle id, version and code signature → move the old app aside, move the new one in → quit; a tiny shell helper waits
/// for this process to exit, opens the new app and deletes the old copy.
@MainActor
final class Updater {
    static let shared = Updater()

    nonisolated static let repo = "itymarcel/soundwatch"
    private static let lastCheckKey = "AudioViz.updateLastCheck"
    private static let skipKey = "AudioViz.updateSkipVersion"

    private var busy = false
    private var panel: NSPanel?
    private var panelLabel: NSTextField?

    struct Release: Sendable {
        let version: String
        let notes: String
        let page: URL
        let zip: URL?
    }

    struct UpdateError: LocalizedError {
        let message: String
        init(_ m: String) { message = m }
        var errorDescription: String? { message }
    }

    nonisolated static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// Harness runs (any AUDIOWATCH_* variable) and bare `swift run` binaries (no .app) never check.
    private static var disabled: Bool {
        ProcessInfo.processInfo.environment.keys.contains { $0.hasPrefix("AUDIOWATCH_") }
            || Bundle.main.bundleURL.pathExtension != "app"
    }

    // MARK: - Entry points

    func checkOnLaunch() {
        guard !Self.disabled else { return }
        let last = UserDefaults.standard.double(forKey: Self.lastCheckKey)
        guard Date().timeIntervalSince1970 - last > 20 * 3600 else { return }
        Task { await check(manual: false) }
    }

    func checkNow() {
        Task { await check(manual: true) }
    }

    private func check(manual: Bool) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        let release: Release
        do {
            release = try await Self.fetchLatest()
        } catch {
            if manual { info("Couldn't check for updates", error.localizedDescription) }
            return   // offline etc.: stay quiet, try again next launch
        }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastCheckKey)
        guard Self.isNewer(release.version, than: Self.currentVersion) else {
            if manual { info("soundwatch is up to date", "You have the latest version (\(Self.currentVersion)).") }
            return
        }
        if !manual, UserDefaults.standard.string(forKey: Self.skipKey) == release.version { return }
        await offer(release, manual: manual)
    }

    private func offer(_ r: Release, manual: Bool) async {
        let a = NSAlert()
        a.messageText = "soundwatch \(r.version) is available"
        var text = "You have \(Self.currentVersion). Your settings and presets are kept."
        let notes = Self.plainNotes(r.notes)
        if !notes.isEmpty { text += "\n\n" + notes }
        a.informativeText = text
        a.addButton(withTitle: "Install & Relaunch")
        a.addButton(withTitle: "Later")
        if !manual { a.addButton(withTitle: "Skip This Version") }
        switch a.runModal() {
        case .alertFirstButtonReturn: await install(r)
        case .alertThirdButtonReturn: UserDefaults.standard.set(r.version, forKey: Self.skipKey)
        default: break
        }
    }

    private func install(_ r: Release) async {
        let appURL = Bundle.main.bundleURL
        if let reason = Self.cannotReplace(appURL) {
            info("Can't update in place", reason + "\n\nThe release page opens so you can download the new version.")
            NSWorkspace.shared.open(r.page)
            return
        }
        guard r.zip != nil else {
            info("No download found", "This release has no app zip attached. The release page opens instead.")
            NSWorkspace.shared.open(r.page)
            return
        }
        showProgress("Downloading soundwatch \(r.version)…")
        do {
            let prepared = try await Self.prepare(r, replacing: appURL)
            setProgress("Installing…")
            try Self.swap(appURL, with: prepared.app, backupIn: prepared.work)
            Self.relaunchAfterExit(appURL, cleanup: prepared.work)
            NSApp.terminate(nil)   // flushes the settings save (willTerminate)
        } catch {
            hideProgress()
            let a = NSAlert()
            a.messageText = "Update failed"
            a.informativeText = error.localizedDescription + "\n\nYour current version was left as it was."
            a.addButton(withTitle: "Open Release Page")
            a.addButton(withTitle: "OK")
            if a.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(r.page) }
        }
    }

    // MARK: - Pipeline (no UI)

    nonisolated static func fetchLatest() async throws -> Release {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("soundwatch-updater", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw UpdateError("GitHub answered with status \(code).") }
        guard let j = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = j["tag_name"] as? String,
              let page = (j["html_url"] as? String).flatMap(URL.init(string:))
        else { throw UpdateError("GitHub's answer didn't look like a release.") }
        let assets = j["assets"] as? [[String: Any]] ?? []
        let zip = assets.first { a in
            guard let n = a["name"] as? String else { return false }
            return n.hasPrefix("soundwatch") && n.hasSuffix(".zip")
        }?["browser_download_url"] as? String
        return Release(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag,
                       notes: j["body"] as? String ?? "", page: page, zip: zip.flatMap(URL.init(string:)))
    }

    /// "1.10" > "1.9"; missing parts count as 0.
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] { s.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 } }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    /// Why the running app can't be replaced where it is (nil = it can).
    nonisolated static func cannotReplace(_ app: URL) -> String? {
        let dir = app.deletingLastPathComponent().path
        if app.path.contains("/AppTranslocation/") {
            return "macOS is running soundwatch from a temporary, read-only copy. Move soundwatch.app into Applications (or any folder), open it from there, and updates can install themselves."
        }
        if dir.hasPrefix("/Volumes/") && !FileManager.default.isWritableFile(atPath: dir) {
            return "soundwatch is running from a disk image or read-only volume."
        }
        if !FileManager.default.isWritableFile(atPath: dir) {
            return "soundwatch doesn't have permission to replace itself in \(dir)."
        }
        return nil
    }

    /// Downloads, unpacks and checks the new app in a scratch folder on the same volume as `appURL`.
    nonisolated static func prepare(_ r: Release, replacing appURL: URL) async throws -> (app: URL, work: URL) {
        guard let zipURL = r.zip else { throw UpdateError("The release has no app zip.") }
        let fm = FileManager.default
        let work = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: appURL, create: true)
        do {
            var req = URLRequest(url: zipURL, timeoutInterval: 60)
            req.setValue("soundwatch-updater", forHTTPHeaderField: "User-Agent")
            let (tmp, resp) = try await URLSession.shared.download(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else { throw UpdateError("The download failed (status \(code)).") }
            let zip = work.appendingPathComponent("update.zip")
            try fm.moveItem(at: tmp, to: zip)

            let unpacked = work.appendingPathComponent("unpacked")
            try await run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path])
            guard let newApp = try fm.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil)
                .first(where: { $0.pathExtension == "app" })
            else { throw UpdateError("The download didn't contain an app.") }

            // Same app, the promised version?
            guard let info = NSDictionary(contentsOf: newApp.appendingPathComponent("Contents/Info.plist")),
                  info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier
            else { throw UpdateError("The downloaded app isn't soundwatch (bundle id differs).") }
            guard info["CFBundleShortVersionString"] as? String == r.version
            else { throw UpdateError("The downloaded app's version doesn't match the release (\(r.version)).") }

            try? await run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", newApp.path])
            try await verifySignature(newApp, against: appURL)
            return (newApp, work)
        } catch {
            try? fm.removeItem(at: work)
            throw error
        }
    }

    /// The new app must have an intact signature. If the running app is signed with a real certificate (not ad-hoc),
    /// the new one must also satisfy the running app's designated requirement, i.e. be signed by the same certificate.
    nonisolated static func verifySignature(_ newApp: URL, against current: URL) async throws {
        do {
            try await run("/usr/bin/codesign", ["--verify", "--deep", "--strict", newApp.path])
        } catch {
            throw UpdateError("The downloaded app's signature is broken.")
        }
        let shown = (try? await run("/usr/bin/codesign", ["-d", "-r-", current.path])) ?? ""
        guard let line = shown.split(separator: "\n").first(where: { $0.contains("designated =>") }) else { return }
        let requirement = line.components(separatedBy: "designated =>").last!.trimmingCharacters(in: .whitespaces)
        if requirement.hasPrefix("cdhash") { return }   // ad-hoc: changes with every build, nothing stable to compare
        do {
            try await run("/usr/bin/codesign", ["--verify", "--deep", "--strict", "-R=" + requirement, newApp.path])
        } catch {
            throw UpdateError("The downloaded app isn't signed by the same developer as this one.")
        }
    }

    /// Moves the running app into `work` and the new one into its place (put back if the second move fails).
    nonisolated static func swap(_ appURL: URL, with newApp: URL, backupIn work: URL) throws {
        let fm = FileManager.default
        let backup = work.appendingPathComponent("previous.app")
        try fm.moveItem(at: appURL, to: backup)
        do {
            try fm.moveItem(at: newApp, to: appURL)
        } catch {
            try? fm.moveItem(at: backup, to: appURL)
            throw error
        }
    }

    /// A detached shell waits for this process to quit, opens the new app and deletes the scratch folder (old copy included).
    nonisolated static func relaunchAfterExit(_ appURL: URL, cleanup work: URL, open: Bool = true) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; "
            + (open ? "/usr/bin/open \"$1\"; " : "") + "/bin/rm -rf \"$2\""
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, "sh", appURL.path, work.path]
        try? p.run()
    }

    @discardableResult
    nonisolated static func run(_ tool: String, _ args: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<String, Error>) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = args
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            p.terminationHandler = { p in
                let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                if p.terminationStatus == 0 { c.resume(returning: out) }
                else { c.resume(throwing: UpdateError("\((tool as NSString).lastPathComponent) failed: \(out)")) }
            }
            do { try p.run() } catch { c.resume(throwing: error) }
        }
    }

    /// Release notes as short plain text for the alert.
    nonisolated static func plainNotes(_ md: String) -> String {
        var lines = md.replacingOccurrences(of: "\r", with: "").split(separator: "\n", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "**", with: "")
                .replacingOccurrences(of: "`", with: "")
                .replacingOccurrences(of: "#", with: "")
                .trimmingCharacters(in: .whitespaces)
        }
        while lines.first?.isEmpty == true { lines.removeFirst() }
        var s = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count > 700 { s = String(s.prefix(700)) + "…" }
        return s
    }

    // MARK: - Small UI helpers

    private func info(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }

    private func showProgress(_ text: String) {
        let label = NSTextField(labelWithString: text)
        let bar = NSProgressIndicator()
        bar.style = .bar
        bar.isIndeterminate = true
        bar.startAnimation(nil)
        let stack = NSStackView(views: [label, bar])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 18, right: 20)
        bar.widthAnchor.constraint(equalToConstant: 280).isActive = true
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 80),
                        styleMask: [.titled], backing: .buffered, defer: false)
        p.title = "Updating soundwatch"
        p.contentView = stack
        p.isReleasedWhenClosed = false
        p.level = .floating
        p.center()
        p.makeKeyAndOrderFront(nil)
        panel = p
        panelLabel = label
    }

    private func setProgress(_ text: String) { panelLabel?.stringValue = text }

    private func hideProgress() {
        panel?.orderOut(nil)
        panel = nil
        panelLabel = nil
    }

    // MARK: - Self-test (terminal)

    /// `AUDIOWATCH_UPDATE_SELFTEST=1 <copy>.app/Contents/MacOS/soundwatch` runs the whole pipeline on that copy without
    /// any UI: fetch, compare, download, check, swap (no relaunch), then exits. Use it on a copy with a lowered version.
    nonisolated static func runSelfTestIfAsked() {
        guard ProcessInfo.processInfo.environment["AUDIOWATCH_UPDATE_SELFTEST"] != nil else { return }
        let done = DispatchSemaphore(value: 0)
        var status: Int32 = 0
        Task.detached {
            do {
                let app = Bundle.main.bundleURL
                let r = try await fetchLatest()
                print("UPDATE current=\(currentVersion) latest=\(r.version) zip=\(r.zip?.absoluteString ?? "none")")
                guard isNewer(r.version, than: currentVersion) else { print("UPDATE up to date"); done.signal(); return }
                if let why = cannotReplace(app) { throw UpdateError(why) }
                let prepared = try await prepare(r, replacing: app)
                print("UPDATE prepared \(prepared.app.path)")
                try swap(app, with: prepared.app, backupIn: prepared.work)
                relaunchAfterExit(app, cleanup: prepared.work, open: false)
                print("UPDATE swapped \(app.path)")
            } catch {
                print("UPDATE error: \(error.localizedDescription)")
                status = 1
            }
            done.signal()
        }
        done.wait()
        exit(status)
    }
}
