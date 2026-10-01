import Foundation
import UIKit
import TheosStudioCore

/// The real filesystem, as the closures the engine expects.
///
/// The engine takes every filesystem question as a parameter so its search order
/// can be tested; this is the one place that answers for real.
enum FS {

    static func fileExists(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        return exists && !isDirectory.boolValue
    }

    static func directoryExists(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    static func list(_ path: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
    }

    static func modificationDate(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    static func size(_ path: String) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.intValue ?? 0
    }

    static func read(_ path: String) -> String? {
        try? String(contentsOfFile: path, encoding: .utf8)
    }

    static func write(_ text: String, to path: String) throws {
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    static func createDirectory(_ path: String) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    static func remove(_ path: String) throws {
        try FileManager.default.removeItem(atPath: path)
    }

    /// A relative-path listing of a project, skipping build directories.
    ///
    /// Shallow on purpose: a project is five files and a `prefs/` subdirectory,
    /// and an unbounded walk would spend its time inside `.theos/`.
    static func projectEntries(at root: String, depth: Int = 2) -> [ProjectEntry] {
        var entries: [ProjectEntry] = []

        func walk(_ directory: String, _ relative: String, _ remaining: Int) {
            guard remaining >= 0 else { return }
            let names = list(directory).sorted()
            for name in names {
                guard !ProjectFiles.isHidden(name) else { continue }
                let path = directory + "/" + name
                let entryPath = relative.isEmpty ? name : relative + "/" + name
                let isDirectory = directoryExists(path)
                if isDirectory {
                    entries.append(ProjectEntry(relativePath: entryPath, isDirectory: true, size: 0))
                    if remaining > 0 {
                        walk(path, entryPath, remaining - 1)
                    }
                } else {
                    entries.append(ProjectEntry(relativePath: entryPath, isDirectory: false, size: size(path)))
                }
            }
        }

        walk(root, "", depth)
        return ProjectFiles.sort(entries)
    }

    /// The directories directly under a root, skipping hidden ones.
    static func subdirectories(of root: String) -> [String] {
        list(root)
            .filter { !$0.hasPrefix(".") }
            .map { root + "/" + $0 }
            .filter { directoryExists($0) }
    }
}

/// Where things live.
enum Paths {

    /// `~/Documents` — inside the app's container when it is sandboxed, and the
    /// real `/var/mobile/Documents` when it is not (which is how the app ships,
    /// so projects are reachable from Filza and from a terminal).
    static var documents: String {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        return url?.path ?? NSHomeDirectory() + "/Documents"
    }

    static var defaultProjectsDirectory: String {
        documents + "/Projects"
    }

    /// Declarative plugin manifests live outside the app bundle so they can be
    /// added with Files, Filza, git or any package manager without rebuilding
    /// TheosStudio.
    static var defaultPluginsDirectory: String {
        documents + "/TheosStudio/Plugins"
    }
}

extension UIApplication {
    /// Opens a file with whatever the device has registered for it — Sileo and
    /// Zebra both claim `.deb`, so a built package can be handed straight to the
    /// package manager instead of being installed by the app's own dpkg call.
    func share(_ url: URL) {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        guard let scene = connectedScenes.first as? UIWindowScene,
              let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController else { return }
        var presenter = root
        while let presented = presenter.presentedViewController { presenter = presented }
        // iPad needs an anchor or it crashes.
        controller.popoverPresentationController?.sourceView = presenter.view
        controller.popoverPresentationController?.sourceRect = CGRect(
            x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 0, height: 0
        )
        presenter.present(controller, animated: true)
    }
}
