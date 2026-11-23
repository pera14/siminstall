import SwiftUI
import AppKit
import CryptoKit

// MARK: - Models

struct Build: Identifiable, Hashable {
    let url: URL
    let date: Date
    let size: Int64
    var id: URL { url }
    var name: String { url.lastPathComponent }
    var isArchive: Bool { url.pathExtension.lowercased() != "app" }
}

/// What we know about the app inside a build, read from its Info.plist.
struct AppInfo: Codable, Hashable {
    let name: String
    let bundleID: String?
    let version: String?
    let build: String?
    /// False only when Info.plist says the app targets real devices, not the simulator.
    let isSimulatorBuild: Bool
    let iconPNG: Data?

    var versionText: String? {
        switch (version, build) {
        case let (v?, b?) where v != b: return "v\(v) (\(b))"
        case let (v?, _): return "v\(v)"
        case let (nil, b?): return "build \(b)"
        default: return nil
        }
    }
}

/// Result of inspecting a build. `noApp` covers archives that aren't simulator builds at all
/// (source tarballs, backups, …) and ones that can't be read.
enum Inspection: Codable, Hashable {
    case app(AppInfo)
    case noApp
}

struct Sim: Identifiable, Hashable {
    let udid: String
    let name: String
    let runtime: String
    let booted: Bool
    var id: String { udid }
    var title: String { "\(name) — \(runtime)\(booted ? "  ●" : "")" }
}

enum Status: Equatable {
    case idle, working(String), success(String), failure(String)
}

// MARK: - Shell

func makeError(_ msg: String) -> NSError {
    NSError(domain: "SimInstall", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
}

@discardableResult
func run(_ exe: String, _ args: [String]) throws -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    let out = Pipe(), err = Pipe()
    p.standardOutput = out
    p.standardError = err
    try p.run()
    let o = out.fileHandleForReading.readDataToEndOfFile()
    let e = err.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    if p.terminationStatus != 0 {
        let msg = String(decoding: e.isEmpty ? o : e, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        throw makeError(msg.isEmpty ? "\(exe) failed (\(p.terminationStatus))" : msg)
    }
    return String(decoding: o, as: UTF8.self)
}

// MARK: - Model

@MainActor
final class Model: ObservableObject {
    static let shared = Model()

    @Published var builds: [Build] = []
    @Published var sims: [Sim] = []
    @Published var selectedBuild: Build.ID?
    @Published var selectedSim: Sim.ID?
    @Published var status: Status = .idle
    @Published var launchAfter = true
    /// Folders scanned for builds (top level only). Persisted; defaults to ~/Downloads.
    @Published var folders: [URL] = Model.loadFolders() {
        didSet { UserDefaults.standard.set(folders.map(\.path), forKey: Model.foldersKey) }
    }
    /// Inspection results per build. A missing entry means it hasn't been read yet.
    @Published var inspections: [Build: Inspection] = [:]
    var inspecting: Set<Build> = []

    var isWorking: Bool { if case .working = status { return true } else { return false } }
    var currentSim: Sim? { sims.first { $0.id == selectedSim } }

    // Scanning

    nonisolated static func isBuild(_ u: URL) -> Bool {
        let n = u.lastPathComponent.lowercased()
        if n.hasSuffix(".tar.gz") || n.hasSuffix(".tgz") { return true }
        // iOS simulator .app bundles are flat (Info.plist at root); macOS apps are not.
        if n.hasSuffix(".app") {
            return FileManager.default.fileExists(atPath: u.appendingPathComponent("Info.plist").path)
        }
        return false
    }

    nonisolated static func dirSize(_ u: URL) -> Int64 {
        var total: Int64 = 0
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey]
        if let e = FileManager.default.enumerator(at: u, includingPropertiesForKeys: keys) {
            for case let f as URL in e {
                total += Int64((try? f.resourceValues(forKeys: Set(keys)).totalFileAllocatedSize) ?? 0)
            }
        }
        return total
    }

    // Folders

    static let foldersKey = "folders"
    nonisolated static var downloadsFolder: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    }

    static func loadFolders() -> [URL] {
        guard let paths = UserDefaults.standard.stringArray(forKey: foldersKey) else { return [downloadsFolder] }
        return paths.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    nonisolated static func isDirectory(_ u: URL) -> Bool {
        (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    func addFolders(_ urls: [URL]) {
        let existing = Set(folders.map { $0.standardizedFileURL.resolvingSymlinksInPath() })
        let new = urls.filter { Model.isDirectory($0) && !Model.isBuild($0) }
            .filter { !existing.contains($0.standardizedFileURL.resolvingSymlinksInPath()) }
        guard !new.isEmpty else { return }
        folders += new
        refresh()
    }

    func chooseFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add Folder"
        panel.message = "Choose folders to scan for simulator builds"
        guard panel.runModal() == .OK else { return }
        addFolders(panel.urls)
    }

    func removeFolder(_ u: URL) {
        folders.removeAll { $0 == u }
        refresh()
    }

    func resetFolders() {
        folders = [Model.downloadsFolder]
        refresh()
    }

    // Scanning builds

    nonisolated static func scanBuilds(in folders: [URL]) -> [Build] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        var seen = Set<URL>()
        var result: [Build] = []
        for dir in folders {
            // Unreadable or deleted folders are skipped; they stay in the menu so the user can remove them.
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys,
                                                          options: [.skipsHiddenFiles]) else { continue }
            for u in items where isBuild(u) {
                // Same file reachable via overlapping folders or symlinks shows once.
                guard seen.insert(u.standardizedFileURL.resolvingSymlinksInPath()).inserted else { continue }
                let v = try? u.resourceValues(forKeys: Set(keys))
                let size = u.pathExtension.lowercased() == "app" ? dirSize(u) : Int64(v?.fileSize ?? 0)
                result.append(Build(url: u, date: v?.contentModificationDate ?? .distantPast, size: size))
            }
        }
        return result.sorted { $0.date > $1.date }
    }

    nonisolated static func loadSims() -> [Sim] {
        guard let json = try? run("/usr/bin/xcrun", ["simctl", "list", "devices", "available", "-j"]),
              let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let devs = obj["devices"] as? [String: [[String: Any]]] else { return [] }
        var result: [Sim] = []
        for (runtime, list) in devs where runtime.contains("iOS") {
            let ver = (runtime.components(separatedBy: "iOS-").last ?? "").replacingOccurrences(of: "-", with: ".")
            for d in list {
                guard let udid = d["udid"] as? String, let name = d["name"] as? String else { continue }
                result.append(Sim(udid: udid, name: name, runtime: "iOS \(ver)",
                                  booted: (d["state"] as? String) == "Booted"))
            }
        }
        return result.sorted {
            if $0.booted != $1.booted { return $0.booted }
            if $0.runtime != $1.runtime { return $0.runtime > $1.runtime }
            return $0.name < $1.name
        }
    }

    /// The top-most `.app` under `dir`. Nested apps (Watch apps, App Clips) are never chosen,
    /// so install and inspection always agree on which app an archive contains.
    nonisolated static func findApp(in dir: URL) -> URL? {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { return nil }
        var best: URL?
        for case let u as URL in e where u.pathExtension.lowercased() == "app" {
            e.skipDescendants()
            if best == nil || u.pathComponents.count < best!.pathComponents.count { best = u }
        }
        return best
    }

    // Inspecting

    nonisolated static func displayName(of app: URL) -> String {
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Info.plist"))
        return (info?["CFBundleDisplayName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (info?["CFBundleName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? app.deletingPathExtension().lastPathComponent
    }

    /// Reads metadata and the best decodable icon from an (possibly partial) `.app` directory.
    nonisolated static func appInfo(at app: URL) -> AppInfo? {
        guard let plist = NSDictionary(contentsOf: app.appendingPathComponent("Info.plist")) else { return nil }
        let platforms = plist["CFBundleSupportedPlatforms"] as? [String] ?? []
        return AppInfo(
            name: displayName(of: app),
            bundleID: plist["CFBundleIdentifier"] as? String,
            version: plist["CFBundleShortVersionString"] as? String,
            build: plist["CFBundleVersion"] as? String,
            isSimulatorBuild: platforms.isEmpty || platforms.contains("iPhoneSimulator"),
            iconPNG: bestIcon(in: app, plist: plist))
    }

    /// Picks the largest icon PNG at the bundle root. Prefers files named in CFBundleIcons;
    /// falls back to anything that looks like an app icon. Icons compiled only into
    /// Assets.car are not readable this way, so this can return nil.
    nonisolated static func bestIcon(in app: URL, plist: NSDictionary) -> Data? {
        var prefixes: [String] = []
        for key in ["CFBundleIcons", "CFBundleIcons~ipad"] {
            let primary = (plist[key] as? [String: Any])?["CFBundlePrimaryIcon"] as? [String: Any]
            prefixes += primary?["CFBundleIconFiles"] as? [String] ?? []
            if let n = primary?["CFBundleIconName"] as? String { prefixes.append(n) }
        }
        if prefixes.isEmpty { prefixes = ["AppIcon"] }

        let files = (try? FileManager.default.contentsOfDirectory(at: app, includingPropertiesForKeys: nil)) ?? []
        let pngs = files.filter { $0.pathExtension.lowercased() == "png" }
        let named = pngs.filter { f in prefixes.contains { f.lastPathComponent.hasPrefix($0) } }
        let candidates = named.isEmpty ? pngs.filter { $0.lastPathComponent.localizedCaseInsensitiveContains("icon") } : named

        var best: (data: Data, pixels: Int)?
        for f in candidates {
            // Device builds ship Apple's "crushed" PNGs, which AppKit can't decode, so skip those.
            guard let data = try? Data(contentsOf: f), data.count < 2_000_000,
                  let rep = NSBitmapImageRep(data: data) else { continue }
            let px = rep.pixelsWide * rep.pixelsHigh
            if px > (best?.pixels ?? 0) { best = (data, px) }
        }
        return best?.data
    }

    /// Reads Info.plist + icons from a build. Archives are streamed once through `tar`, and only
    /// the few metadata files are written to disk, so even large archives finish in well under a second.
    nonisolated static func inspect(_ url: URL) -> Inspection {
        if url.pathExtension.lowercased() == "app" {
            return appInfo(at: url).map(Inspection.app) ?? .noApp
        }
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("siminstall-inspect-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        guard (try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)) != nil else { return .noApp }
        // bsdtar's `*` also matches `/`, so this pulls nested apps' plists too; findApp picks the top one.
        // The exit status is ignored on purpose: bsdtar fails when any --include pattern matches nothing
        // (e.g. an app whose icons live only in Assets.car). What got extracted is what counts; a corrupt
        // or non-gzip file simply extracts no .app and ends up as .noApp.
        _ = try? run("/usr/bin/tar", ["-xzf", url.path, "-C", tmp.path,
                                      "--include", "*.app/Info.plist",
                                      "--include", "*.app/*Icon*.png"])
        guard let app = findApp(in: tmp), let info = appInfo(at: app) else { return .noApp }
        return .app(info)
    }


    // Loading

    func reloadSims() async {
        let s = await Task.detached { Model.loadSims() }.value
        sims = s
        if selectedSim == nil || !s.contains(where: { $0.id == selectedSim }) {
            selectedSim = (s.first(where: \.booted) ?? s.first)?.id
        }
    }

    func refresh() {
        Task {
            await reloadSims()
            let dirs = folders
            builds = await Task.detached { Model.scanBuilds(in: dirs) }.value
            if selectedBuild == nil || !builds.contains(where: { $0.id == selectedBuild }) {
                selectedBuild = builds.first?.id
            }
            inspectPendingBuilds()
        }
    }

    func handleOpen(_ urls: [URL]) {
        // Dropped folders (that aren't .app bundles) are added to the scanned folders.
        let dirs = urls.filter { Model.isDirectory($0) && !Model.isBuild($0) }
        if !dirs.isEmpty {
            addFolders(dirs)
            let names = dirs.map(\.lastPathComponent).joined(separator: ", ")
            status = .success("Scanning \(names) for builds")
        }
        guard let u = urls.first(where: Model.isBuild) else {
            if dirs.isEmpty { status = .failure("Not a simulator build (.app or .tar.gz) or a folder") }
            return
        }
        Task {
            if sims.isEmpty { await reloadSims() }
            if let s = currentSim { install(url: u, sim: s) }
            else { status = .failure("No iOS simulators found") }
        }
    }

    // Installing

    func install() {
        guard let b = builds.first(where: { $0.id == selectedBuild }), let s = currentSim else { return }
        install(url: b.url, sim: s)
    }

    func install(url: URL, sim: Sim) {
        guard !isWorking else { return }
        status = .working("Preparing…")
        let launch = launchAfter
        Task.detached {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("siminstall-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: tmp) }
            do {
                var app = url
                if url.pathExtension.lowercased() != "app" {
                    await Model.shared.set(.working("Extracting \(url.lastPathComponent)…"))
                    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
                    try run("/usr/bin/tar", ["-xzf", url.path, "-C", tmp.path])
                    guard let found = Model.findApp(in: tmp) else { throw makeError("No .app found in archive") }
                    app = found
                }
                if !sim.booted {
                    await Model.shared.set(.working("Booting \(sim.name)…"))
                    _ = try? run("/usr/bin/xcrun", ["simctl", "boot", sim.udid])
                    _ = try? run("/usr/bin/xcrun", ["simctl", "bootstatus", sim.udid])
                }
                let appName = Model.displayName(of: app)
                await Model.shared.set(.working("Installing \(appName) on \(sim.name)…"))
                try run("/usr/bin/xcrun", ["simctl", "install", sim.udid, app.path])
                if launch,
                   let info = NSDictionary(contentsOf: app.appendingPathComponent("Info.plist")),
                   let bundleID = info["CFBundleIdentifier"] as? String {
                    _ = try? run("/usr/bin/xcrun", ["simctl", "launch", sim.udid, bundleID])
                }
                await Model.shared.set(.success("Installed \(appName) on \(sim.name)"))
                await Model.shared.reloadSims()
            } catch {
                await Model.shared.set(.failure(error.localizedDescription))
            }
        }
    }

    func set(_ s: Status) { status = s }
}

// MARK: - Inspection cache

/// Disk cache keyed by path + modification date + size, so each build is inspected only once,
/// even across launches. A changed or re-downloaded file gets a new key automatically.
enum InspectionCache {
    static let dir: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("SimInstall/AppInfo-v2", isDirectory: true)
    }()

    static func file(for b: Build) -> URL {
        let key = "\(b.url.path)|\(b.date.timeIntervalSince1970)|\(b.size)"
        let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return dir.appendingPathComponent("\(hash).json")
    }

    static func load(_ b: Build) -> Inspection {
        let f = file(for: b)
        if let data = try? Data(contentsOf: f),
           let cached = try? JSONDecoder().decode(Inspection.self, from: data) {
            return cached
        }
        let result = Model.inspect(b.url)
        if let data = try? JSONEncoder().encode(result) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? data.write(to: f, options: .atomic)
        }
        return result
    }
}

extension Model {
    /// Inspects builds that have no result yet, two at a time, publishing each one as it finishes.
    func inspectPendingBuilds() {
        let current = Set(builds)
        inspections = inspections.filter { current.contains($0.key) }
        let pending = builds.filter { inspections[$0] == nil && !inspecting.contains($0) }
        guard !pending.isEmpty else { return }
        inspecting.formUnion(pending)

        Task.detached(priority: .utility) {
            await withTaskGroup(of: (Build, Inspection).self) { group in
                var queue = pending.makeIterator()
                for _ in 0..<2 {
                    if let b = queue.next() { group.addTask { (b, InspectionCache.load(b)) } }
                }
                while let (b, result) = await group.next() {
                    await Model.shared.finishInspection(b, result)
                    if let b = queue.next() { group.addTask { (b, InspectionCache.load(b)) } }
                }
            }
        }
    }

    func finishInspection(_ b: Build, _ result: Inspection) {
        inspecting.remove(b)
        if builds.contains(b) { inspections[b] = result }
    }

    func appInfo(for b: Build) -> AppInfo? {
        if case .app(let info)? = inspections[b] { return info }
        return nil
    }
}

// MARK: - Views

struct ContentView: View {
    @ObservedObject var m = Model.shared
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            buildList
            Divider()
            footer
        }
        .frame(minWidth: 620, minHeight: 440)
        .onAppear { m.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if !m.isWorking { m.refresh() }
        }
        .dropDestination(for: URL.self) { urls, _ in
            m.handleOpen(urls)
            return true
        } isTargeted: { dropTargeted = $0 }
        .overlay { if dropTargeted { dropOverlay } }
    }

    var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text("SimInstall").font(.title3.weight(.semibold))
                Text("Install dev builds on the iOS Simulator")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Simulator", selection: $m.selectedSim) {
                ForEach(m.sims) { s in Text(s.title).tag(Optional(s.id)) }
            }
            .labelsHidden()
            .frame(width: 280)
            foldersMenu
            Button { m.refresh() } label: { Image(systemName: "arrow.clockwise") }
                .help("Refresh builds and simulators")
        }
        .padding(16)
    }

    var foldersMenu: some View {
        Menu {
            Section("Scanned folders") {
                ForEach(m.folders, id: \.self) { f in
                    Menu {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([f]) }
                        Button("Remove", role: .destructive) { m.removeFolder(f) }
                    } label: {
                        Label(f.lastPathComponent, systemImage: "folder")
                    }
                    .help(f.path)
                }
            }
            Divider()
            Button("Add Folder…") { m.chooseFolders() }
            if m.folders != [Model.downloadsFolder] {
                Button("Reset to Downloads") { m.resetFolders() }
            }
        } label: {
            Image(systemName: "folder")
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Folders to scan for builds")
    }

    private var foldersDescription: String {
        let names = m.folders.map(\.lastPathComponent)
        switch names.count {
        case 0: return "No folders selected"
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default: return "\(names[0]) and \(names.count - 1) other folders"
        }
    }

    @ViewBuilder var buildList: some View {
        if m.builds.isEmpty {
            ContentUnavailableView {
                Label(m.folders.isEmpty ? "No folders to scan" : "No builds in \(foldersDescription)",
                      systemImage: "shippingbox")
            } description: {
                Text("Download an EAS simulator build, add a folder that contains builds, or drop a .app / .tar.gz here.")
            } actions: {
                Button("Add Folder…") { m.chooseFolders() }
            }
            .frame(maxHeight: .infinity)
        } else {
            List(m.builds, selection: $m.selectedBuild) { b in
                BuildRow(build: b, inspection: m.inspections[b])
            }
            .listStyle(.inset)
            .contextMenu(forSelectionType: Build.ID.self) { ids in
                if let id = ids.first {
                    Button("Install") { m.selectedBuild = id; m.install() }
                    if let b = m.builds.first(where: { $0.id == id }),
                       let bundleID = m.appInfo(for: b)?.bundleID {
                        Button("Copy Bundle ID") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(bundleID, forType: .string)
                        }
                    }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([id]) }
                }
            } primaryAction: { ids in
                if let id = ids.first { m.selectedBuild = id; m.install() }
            }
        }
    }

    var footer: some View {
        HStack(spacing: 14) {
            statusView
            Spacer()
            Toggle("Launch after install", isOn: $m.launchAfter)
                .toggleStyle(.checkbox)
            Button {
                m.install()
            } label: {
                Text("Install").frame(minWidth: 70)
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(m.selectedBuild == nil || m.selectedSim == nil || m.isWorking)
        }
        .padding(16)
    }

    @ViewBuilder var statusView: some View {
        switch m.status {
        case .idle:
            Label("Double-click a build, or drop one anywhere", systemImage: "arrow.down.app")
                .foregroundStyle(.secondary)
        case .working(let t):
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text(t).lineLimit(1) }
        case .success(let t):
            Label(t, systemImage: "checkmark.circle.fill").foregroundStyle(.green).lineLimit(1)
        case .failure(let t):
            Label(t, systemImage: "xmark.octagon.fill").foregroundStyle(.red).lineLimit(2).help(t)
                .textSelection(.enabled)
        }
    }

    var dropOverlay: some View {
        RoundedRectangle(cornerRadius: 16)
            .fill(Color.accentColor.opacity(0.08))
            .overlay(RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 6])))
            .overlay(Label("Drop to install on \(m.currentSim?.name ?? "simulator")",
                           systemImage: "arrow.down.circle.fill")
                .font(.title2.weight(.semibold))
                .foregroundStyle(Color.accentColor))
            .padding(10)
            .allowsHitTesting(false)
    }
}

struct BuildRow: View {
    let build: Build
    /// nil while the build is still being read.
    let inspection: Inspection?

    private var info: AppInfo? { if case .app(let i)? = inspection { return i } else { return nil } }
    private var kind: String { build.isArchive ? "EAS archive" : "App bundle" }
    private var fallbackTitle: String {
        build.isArchive ? build.name : build.url.deletingPathExtension().lastPathComponent
    }

    var body: some View {
        HStack(spacing: 12) {
            icon.frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(info?.name ?? fallbackTitle)
                    .lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(inspection == .noApp ? .secondary : .primary)
                subtitle
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(build.date, format: .relative(presentation: .named)).font(.callout)
                Text(ByteCountFormatter.string(fromByteCount: build.size, countStyle: .file))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 5)
        .help((build.url.path as NSString).abbreviatingWithTildeInPath)
    }

    @ViewBuilder private var icon: some View {
        if let data = info?.iconPNG, let img = NSImage(data: data) {
            Image(nsImage: img)
                .resizable().interpolation(.high)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
        } else if inspection == nil {
            ProgressView().controlSize(.small)
        } else {
            Image(systemName: inspection == .noApp ? "questionmark.folder.fill"
                  : build.isArchive ? "shippingbox.fill" : "app.fill")
                .font(.title2)
                .foregroundStyle(inspection == .noApp ? Color.secondary
                                 : build.isArchive ? Color.orange : Color.accentColor)
        }
    }

    private var subtitle: Text {
        switch inspection {
        case nil:
            return Text(build.isArchive ? "Reading archive…" : "Reading app…")
        case .noApp?:
            return Text(build.isArchive ? "No simulator app inside" : "Unreadable app bundle")
        case .app(let i)?:
            let parts = [i.bundleID, i.versionText, kind].compactMap { $0 }
            let text = Text(parts.joined(separator: " · "))
            guard !i.isSimulatorBuild else { return text }
            return Text("Device build").foregroundColor(.orange).bold() + Text(" · ") + text
        }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    // Files dropped on the Dock icon / "Open With"
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in Model.shared.handleOpen(urls) }
    }
}

@main
struct SimInstallApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        Window("SimInstall", id: "main") { ContentView() }
            .windowResizability(.contentMinSize)
            .defaultSize(width: 680, height: 500)
            .commands {
                CommandGroup(replacing: .newItem) {
                    Button("Add Folder…") { Model.shared.chooseFolders() }
                        .keyboardShortcut("o")
                }
            }
    }
}
