import Foundation
import TheosStudioCore

/// How much to read before saying so — file scope, so the walk can consult it
/// from a background task without touching main-actor state. 3000 headers is
/// about 20 MB, which a phone reads in a second or two and which covers the
/// framework you are interested in.
enum HeaderIndexLimits {
    static let files = 3000
    static let bytes = 40 * 1024 * 1024
}

/// Reads headers so a class name can be confirmed before it is hooked.
///
/// Two sources, both of them just text on the device: the SDK headers inside
/// `$THEOS/sdks` (public API, and what a framework hook has to match) and any
/// folder of dumped private headers the user points at. The walk is bounded — an
/// iPhoneOS SDK holds tens of thousands of headers and a phone should not read
/// all of them to answer one question.
@MainActor
final class HeaderIndexer: ObservableObject {

    enum Source: String, CaseIterable, Identifiable {
        case sdk
        case custom

        var id: String { rawValue }

        var title: String {
            switch self {
            case .sdk: return "Theos SDK"
            case .custom: return "My header folder"
            }
        }
    }

    @Published private(set) var isIndexing = false
    @Published private(set) var indexedFiles = 0
    @Published private(set) var truncated = false
    @Published private(set) var declarations: [HeaderDeclaration] = []
    @Published private(set) var message: String?

    func index(roots: [String]) {
        guard !isIndexing else { return }
        isIndexing = true
        declarations = []
        indexedFiles = 0
        truncated = false
        message = nil

        Task.detached(priority: .userInitiated) {
            let result = await Self.walk(roots: roots)
            await MainActor.run {
                self.apply(result)
            }
        }
    }

    /// Searches, reading the headers first if nothing has been read yet. This is
    /// what the assistant calls: it should not have to know that an index exists.
    func searchOrIndex(_ query: String, roots: [String]) async -> [HeaderDeclaration] {
        if declarations.isEmpty, !isIndexing {
            isIndexing = true
            let result = await Self.walk(roots: roots)
            apply(result)
        }
        return HeaderIndex.search(query, in: declarations)
    }

    func search(_ query: String) -> [HeaderDeclaration] {
        HeaderIndex.search(query, in: declarations)
    }

    private func apply(_ result: WalkResult) {
        declarations = result.declarations
        indexedFiles = result.files
        truncated = result.truncated
        isIndexing = false
        if result.declarations.isEmpty {
            message = "No declarations were found. Point \"My header folder\" at a dump of the headers you care about (Flex, a dumpdecrypted app, or the SDK)."
        } else if result.truncated {
            message = "Read the first \(result.files) headers and stopped — searches are answered from those."
        }
    }

    struct WalkResult: Sendable {
        var declarations: [HeaderDeclaration] = []
        var files = 0
        var truncated = false
    }

    /// The walk itself, nonisolated so it can run off the main actor.
    nonisolated static func walk(roots: [String]) async -> WalkResult {
        var result = WalkResult()
        var bytes = 0
        let roots = roots.filter { FS.directoryExists($0) }
        guard !roots.isEmpty else { return result }

        for root in roots {
            var queue = [root]
            while let directory = queue.popLast() {
                if result.files >= HeaderIndexLimits.files || bytes >= HeaderIndexLimits.bytes {
                    result.truncated = true
                    break
                }
                for entry in FS.list(directory).sorted() {
                    let path = directory + "/" + entry
                    if FS.directoryExists(path) {
                        // Frameworks and module wrappers are walked; hidden
                        // directories are not.
                        if !entry.hasPrefix(".") { queue.append(path) }
                    } else if entry.hasSuffix(".h") || entry.hasSuffix(".hpp") || entry.hasSuffix(".hh") {
                        guard result.files < HeaderIndexLimits.files, bytes < HeaderIndexLimits.bytes else {
                            result.truncated = true
                            break
                        }
                        result.files += 1
                        guard let text = FS.read(path), text.utf8.count < 2 * 1024 * 1024 else { continue }
                        bytes += text.utf8.count
                        result.declarations.append(contentsOf: HeaderIndex.declarations(in: text, file: path))
                    }
                }
            }
        }
        return result
    }

    /// The SDK roots to read: every SDK Theos has, newest first, so the newest
    /// framework headers win a tie.
    static func sdkRoots(theosRoot: String?) -> [String] {
        guard let theosRoot else { return [] }
        let sdks = theosRoot + "/sdks"
        return FS.list(sdks)
            .filter { $0.hasSuffix(".sdk") }
            .sorted(by: >)
            .map { sdks + "/" + $0 + "/System/Library/Frameworks" }
            .filter { FS.directoryExists($0) }
    }
}
