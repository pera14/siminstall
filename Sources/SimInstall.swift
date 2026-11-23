import SwiftUI
import AppKit

// MARK: - Models

struct Build: Identifiable, Hashable {
    let url: URL
    let date: Date
    let size: Int64
    var id: URL { url }
    var name: String { url.lastPathComponent }
    var isArchive: Bool { url.pathExtension.lowercased() != "app" }
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

    nonisolated static func scanBuilds() -> [Build] {
        let fm = FileManager.default
        let dir = fm.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys,
                                                      options: [.skipsHiddenFiles]) else { return [] }
        return items.filter(isBuild).map { u in
            let v = try? u.resourceValues(forKeys: Set(keys))
            let size = u.pathExtension.lowercased() == "app" ? dirSize(u) : Int64(v?.fileSize ?? 0)
            return Build(url: u, date: v?.contentModificationDate ?? .distantPast, size: size)
        }.sorted { $0.date > $1.date }
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

    nonisolated static func findApp(in dir: URL) -> URL? {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { return nil }
        for case let u as URL in e where u.pathExtension == "app" { return u }
        return nil
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
            builds = await Task.detached { Model.scanBuilds() }.value
            if selectedBuild == nil || !builds.contains(where: { $0.id == selectedBuild }) {
                selectedBuild = builds.first?.id
            }
        }
    }

    func handleOpen(_ urls: [URL]) {
        guard let u = urls.first(where: Model.isBuild) else {
            status = .failure("Not a simulator build (.app or .tar.gz)")
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
                let appName = app.deletingPathExtension().lastPathComponent
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
            Button { m.refresh() } label: { Image(systemName: "arrow.clockwise") }
                .help("Refresh builds and simulators")
        }
        .padding(16)
    }

    @ViewBuilder var buildList: some View {
        if m.builds.isEmpty {
            ContentUnavailableView("No builds in Downloads",
                                   systemImage: "shippingbox",
                                   description: Text("Download an EAS simulator build, or drop a .app / .tar.gz here."))
                .frame(maxHeight: .infinity)
        } else {
            List(m.builds, selection: $m.selectedBuild) { b in
                HStack(spacing: 12) {
                    Image(systemName: b.isArchive ? "shippingbox.fill" : "app.fill")
                        .font(.title2)
                        .foregroundStyle(b.isArchive ? Color.orange : Color.accentColor)
                        .frame(width: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(b.isArchive ? b.name : b.url.deletingPathExtension().lastPathComponent)
                            .lineLimit(1).truncationMode(.middle)
                        Text(b.isArchive ? "EAS archive (.tar.gz)" : "App bundle (.app)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(b.date, format: .relative(presentation: .named)).font(.callout)
                        Text(ByteCountFormatter.string(fromByteCount: b.size, countStyle: .file))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 5)
            }
            .listStyle(.inset)
            .contextMenu(forSelectionType: Build.ID.self) { ids in
                if let id = ids.first {
                    Button("Install") { m.selectedBuild = id; m.install() }
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
    }
}
