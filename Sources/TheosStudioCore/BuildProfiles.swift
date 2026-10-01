import Foundation

public enum BuildProfile: String, CaseIterable, Sendable {
    case debug
    case fast
    case release
    case rebuild

    public var displayName: String {
        switch self {
        case .debug: return "Debug"
        case .fast: return "Fast Iteration"
        case .release: return "Release"
        case .rebuild: return "Clean Rebuild"
        }
    }

    public func applying(to request: BuildRequest) -> BuildRequest {
        var result = request
        switch self {
        case .debug:
            result.finalPackage = false
            result.cleanFirst = false
            result.verbose = true
        case .fast:
            result.finalPackage = false
            result.cleanFirst = false
            result.verbose = false
            if result.jobs == nil { result.jobs = max(2, ProcessInfo.processInfo.activeProcessorCount) }
        case .release:
            result.finalPackage = true
            result.cleanFirst = true
            result.verbose = true
        case .rebuild:
            result.finalPackage = false
            result.cleanFirst = true
            result.verbose = true
        }
        return result
    }
}
