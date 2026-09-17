import Darwin
import Foundation

enum POSIXTmuxProcessError: Error, Equatable {
    case pseudoTerminal(Int32)
    case processNotRunning
    case resize(Int32)
}

/// Launches one tmux client with a real pseudo-terminal. `Process` performs the spawn, avoiding a
/// direct `fork` inside the multithreaded app, while the PTY master remains owned by the host.
@MainActor
final class POSIXTmuxParticipantProcess: TerminalParticipantProcess, @unchecked Sendable {
    var onOutput: ((Data) -> Void)?
    var onExit: ((Int32) -> Void)?

    private let executableURL: URL
    private let arguments: [String]
    private var process: Process?
    private var masterHandle: FileHandle?
    private var masterDescriptor: Int32 = -1

    init(executableURL: URL, arguments: [String]) {
        self.executableURL = executableURL
        self.arguments = arguments
    }

    func start() throws {
        guard process == nil else { return }

        var master: Int32 = -1
        var slave: Int32 = -1
        var initialSize = winsize()
        initialSize.ws_col = 80
        initialSize.ws_row = 24
        guard openpty(&master, &slave, nil, nil, &initialSize) == 0 else {
            throw POSIXTmuxProcessError.pseudoTerminal(errno)
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = environment["TERM"] ?? "xterm-256color"
        process.environment = environment

        let standardInput = FileHandle(fileDescriptor: dup(slave), closeOnDealloc: true)
        let standardOutput = FileHandle(fileDescriptor: dup(slave), closeOnDealloc: true)
        let standardError = FileHandle(fileDescriptor: dup(slave), closeOnDealloc: true)
        process.standardInput = standardInput
        process.standardOutput = standardOutput
        process.standardError = standardError

        let masterHandle = FileHandle(fileDescriptor: master, closeOnDealloc: true)
        masterHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor [weak self] in self?.onOutput?(data) }
        }
        process.terminationHandler = { [weak self] process in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.masterHandle?.readabilityHandler = nil
                self.onExit?(process.terminationStatus)
            }
        }

        do {
            try process.run()
        } catch {
            masterHandle.readabilityHandler = nil
            try? masterHandle.close()
            close(slave)
            throw error
        }
        close(slave)

        self.process = process
        self.masterHandle = masterHandle
        self.masterDescriptor = master
    }

    func sendInput(_ data: Data) throws {
        guard let masterHandle, process?.isRunning == true else {
            throw POSIXTmuxProcessError.processNotRunning
        }
        try masterHandle.write(contentsOf: data)
    }

    func resize(_ size: TerminalResize) throws {
        guard masterDescriptor >= 0, process?.isRunning == true else {
            throw POSIXTmuxProcessError.processNotRunning
        }

        var windowSize = winsize()
        windowSize.ws_col = size.columns
        windowSize.ws_row = size.rows
        guard ioctl(masterDescriptor, TIOCSWINSZ, &windowSize) == 0 else {
            throw POSIXTmuxProcessError.resize(errno)
        }
    }

    func stop() {
        masterHandle?.readabilityHandler = nil
        if process?.isRunning == true { process?.terminate() }
        try? masterHandle?.close()
        masterHandle = nil
        masterDescriptor = -1
        process = nil
    }
}

enum TmuxExecutableLocator {
    static func locate(fileManager: FileManager = .default) -> URL? {
        [
            "/opt/homebrew/bin/tmux",
            "/usr/local/bin/tmux",
            "/usr/bin/tmux",
        ]
        .first(where: { fileManager.isExecutableFile(atPath: $0) })
        .map { URL(fileURLWithPath: $0) }
    }
}
