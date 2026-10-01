import Foundation

/// Runs a child process and streams its combined standard output and error.
///
/// `Foundation.Process` is unavailable on iOS, and `posix_spawn_file_actions_addchdir_np`
/// is unavailable there too, so the working directory is never changed: callers
/// pass an absolute path as an argument (`make -C <project>`) instead.
final class ShellProcess {

    struct Outcome {
        let status: Int32
        let output: String
        var succeeded: Bool { status == 0 }
    }

    enum Failure: LocalizedError {
        case pipe(errno: Int32)
        case spawn(executable: String, code: Int32)

        var errorDescription: String? {
            switch self {
            case .pipe(let code):
                return "Could not create a pipe (errno \(code))."
            case .spawn(let executable, let code):
                return "Could not run \(executable) (spawn error \(code)). It may be missing, or not executable by this app."
            }
        }
    }

    let executable: String
    let arguments: [String]
    let environment: [String: String]

    private let lock = NSLock()
    private var pid: pid_t = 0
    private var finished = false

    init(executable: String, arguments: [String], environment: [String: String]) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
    }

    var commandLine: String {
        ([executable] + arguments)
            .map { $0.contains(" ") ? "'\($0)'" : $0 }
            .joined(separator: " ")
    }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return pid != 0 && !finished
    }

    /// Starts the process. `onLine` is called on the main queue once per complete
    /// line; `onExit` is called on the main queue when the process is gone.
    func run(onLine: @escaping (String) -> Void, onExit: @escaping (Outcome) -> Void) throws {
        var descriptors: [Int32] = [-1, -1]
        guard pipe(&descriptors) == 0 else { throw Failure.pipe(errno: errno) }

        var actions: posix_spawn_file_actions_t?
        _ = posix_spawn_file_actions_init(&actions)
        // One pipe for both streams: the order the compiler and make print in is
        // the order a terminal would show, and interleaving is what makes a build
        // log readable.
        _ = posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDOUT_FILENO)
        _ = posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDERR_FILENO)
        _ = posix_spawn_file_actions_addclose(&actions, descriptors[0])
        _ = posix_spawn_file_actions_addclose(&actions, descriptors[1])

        var argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) }
        argv.append(nil)
        var envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") }
        envp.append(nil)

        var child: pid_t = 0
        let result = posix_spawn(&child, executable, &actions, nil, &argv, &envp)
        posix_spawn_file_actions_destroy(&actions)
        for pointer in argv where pointer != nil { free(pointer) }
        for pointer in envp where pointer != nil { free(pointer) }

        guard result == 0 else {
            close(descriptors[0])
            close(descriptors[1])
            throw Failure.spawn(executable: executable, code: result)
        }

        // The parent must close its copy of the write end, or the read below
        // never sees end of file.
        close(descriptors[1])
        lock.lock()
        pid = child
        lock.unlock()

        let readDescriptor = descriptors[0]
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var collected = ""
            var backlog: [UInt8] = []
            var buffer = [UInt8](repeating: 0, count: 8192)

            while true {
                let count = read(readDescriptor, &buffer, buffer.count)
                if count > 0 {
                    backlog.append(contentsOf: buffer[0..<count])
                    // Hold back a trailing partial UTF-8 sequence so a multi-byte
                    // character split across two reads is not mangled.
                    let decodable = Self.completePrefix(of: backlog)
                    let text = String(decoding: backlog[0..<decodable], as: UTF8.self)
                    backlog.removeFirst(decodable)
                    collected += text
                    var remainder = text
                    while let index = remainder.firstIndex(where: { $0 == "\n" }) {
                        let line = String(remainder[remainder.startIndex..<index])
                        remainder = String(remainder[remainder.index(after: index)...])
                        let trimmed = line.hasSuffix("\r") ? String(line.dropLast()) : line
                        DispatchQueue.main.async { onLine(trimmed) }
                    }
                    self?.partial = remainder
                    continue
                }
                if count < 0 && errno == EINTR { continue }
                break
            }
            close(readDescriptor)

            var status: Int32 = 0
            waitpid(child, &status, 0)
            if let leftover = self?.partial, !leftover.isEmpty {
                let line = leftover
                self?.partial = ""
                DispatchQueue.main.async { onLine(line) }
            }

            // The wait(2) status word is not a plain exit code: the low seven
            // bits hold the signal that killed the child (0 when it exited on
            // its own) and the next byte is the exit status. Swift does not
            // import the function-like macros that read it — WIFEXITED,
            // WIFSIGNALED and WTERMSIG are "function like macros not supported"
            // — so the layout is spelled out rather than guessed at.
            let signal = status & 0x7F
            let code: Int32
            if signal == 0 {
                code = (status >> 8) & 0xFF
            } else if signal != 0x7F {
                // Killed by a signal: report it the way a shell does, so a
                // cancelled build and a crashed compiler read differently.
                code = 128 + signal
            } else {
                code = status
            }

            self?.lock.lock()
            self?.finished = true
            self?.lock.unlock()

            let outcome = Outcome(status: code, output: collected)
            DispatchQueue.main.async { onExit(outcome) }
        }
    }

    /// SIGTERM: make forwards nothing, but the compiler processes it started are
    /// children of make and go with it in practice. A build that ignores it is
    /// left alone rather than SIGKILLed, because a half-written .deb is worse
    /// than a slow cancel.
    func terminate() {
        lock.lock()
        let child = pid
        lock.unlock()
        if child > 0 {
            kill(child, SIGTERM)
        }
    }

    /// The number of leading bytes that form complete UTF-8 sequences.
    private static func completePrefix(of bytes: [UInt8]) -> Int {
        guard let last = bytes.last else { return 0 }
        // ASCII: everything is complete.
        if last < 0x80 { return bytes.count }
        var trail = 0
        var index = bytes.count - 1
        while index >= 0, bytes[index] & 0xC0 == 0x80 {
            trail += 1
            index -= 1
        }
        guard index >= 0 else { return bytes.count }
        let lead = bytes[index]
        let expected: Int
        switch lead {
        case 0xC0...0xDF: expected = 1
        case 0xE0...0xEF: expected = 2
        case 0xF0...0xF7: expected = 3
        default: return bytes.count
        }
        return trail < expected ? index : bytes.count
    }

    /// The tail of the last line, kept between reads.
    private var partial = ""
}

/// Convenience for the many short-lived commands the app runs (probing a tool,
/// installing a package) where the output is only wanted at the end.
enum CommandRunner {

    @discardableResult
    static func run(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String]? = nil,
        completion: @escaping (ShellProcess.Outcome) -> Void
    ) -> ShellProcess {
        let process = ShellProcess(
            executable: executable,
            arguments: arguments,
            environment: environment ?? ProcessInfo.processInfo.environment
        )
        do {
            try process.run(onLine: { _ in }, onExit: completion)
        } catch {
            completion(ShellProcess.Outcome(status: 127, output: error.localizedDescription))
        }
        return process
    }
}
