import Foundation

/// The local model FrameFold categorises with: Liquid AI's d1-3B vision decision model, run by
/// Ollaya (https://github.com/ollaya-dev/ollaya). It looks at each photo and returns calibrated
/// probabilities over the categories in one forward pass; nothing is generated.
enum LocalModel {
    static let name = "d1:3b-vision"
    static let displayName = "d1 3B Vision"
    static let summary = "Liquid AI's d1-3B on LFM2.5-VL, run locally by Ollaya. It looks at each photo itself."
    /// Size of the Q8_0 weights, from the model's decision.json on Hugging Face (projector excluded).
    static let approximateBytes: Int64 = 2_874_781_280
    /// Largest number of choice options sent in one question.
    static let maxOptions = 20

    /// Matches a name from `/api/tags` against this model.
    static func matches(_ tag: String) -> Bool {
        tag == name || tag.hasSuffix("/\(name)")
    }

    /// Path of the model's manifest in Ollaya's store, relative to `manifests/`.
    static let manifestSuffix = "/d1/3b-vision"
}

/// Installs and drives the local model through the Ollaya runtime, all on this Mac.
///
/// Each photo goes to `POST /api/decide` as a PNG in `images` with a one-line state. The server is
/// started on demand and the model is unloaded when a run finishes.
@MainActor
final class LocalModelService: ObservableObject {
    enum State: Equatable {
        case checking
        case runtimeMissing
        case installingRuntime
        case modelMissing
        case pullingModel(status: String, completed: Int64, total: Int64)
        case ready
        case failed(String)
    }

    @Published private(set) var state: State = .checking
    @Published private(set) var log: [String] = []

    private let base = URL(string: "http://127.0.0.1:11435")!
    private var serverProcess: Process?
    private var installTask: Task<Void, Never>?

    /// Where FrameFold installs the Ollaya runtime: `~/Library/Application Support/FrameFold/Ollaya`.
    var installPrefix: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("FrameFold/Ollaya", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Where Ollaya keeps downloaded models: `~/.ollaya/models` (its default store).
    var modelStore: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ollaya/models", isDirectory: true)
    }

    var binaryURL: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            installPrefix.appendingPathComponent("bin/ollaya"),
            home.appendingPathComponent(".local/bin/ollaya"),
            URL(fileURLWithPath: "/usr/local/bin/ollaya"),
            URL(fileURLWithPath: "/opt/homebrew/bin/ollaya"),
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    var isReady: Bool { state == .ready }
    var isBusy: Bool {
        switch state {
        case .installingRuntime, .pullingModel, .checking: return true
        default: return false
        }
    }

    // MARK: Status

    /// Works out whether the runtime and model are present, without starting anything.
    func refresh() async {
        guard installTask == nil else { return }
        state = .checking
        if await isServerAlive() {
            state = await hasModel() ? .ready : .modelMissing
            return
        }
        guard binaryURL != nil else {
            state = .runtimeMissing
            return
        }
        // The model store is plain files, so check it without starting the daemon.
        let store = modelStore.appendingPathComponent("manifests")
        let found = FileManager.default.enumerator(at: store, includingPropertiesForKeys: nil)?
            .contains { ($0 as? URL)?.path.hasSuffix(LocalModel.manifestSuffix) == true } ?? false
        state = found ? .ready : .modelMissing
    }

    // MARK: Install

    /// Installs the Ollaya runtime if needed, then downloads the selected model.
    func install() {
        guard installTask == nil else { return }
        installTask = Task {
            defer { installTask = nil }
            do {
                if binaryURL == nil {
                    state = .installingRuntime
                    try await installRuntime()
                }
                try await ensureServer()
                if !(await hasModel()) {
                    try await pullModel()
                }
                state = .ready
                await unload()
            } catch is CancellationError {
                state = binaryURL == nil ? .runtimeMissing : .modelMissing
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    func cancelInstall() {
        installTask?.cancel()
    }

    /// Deletes the selected model from Ollaya's store; the runtime stays.
    func removeModel() async {
        do {
            try await ensureServer()
            var request = URLRequest(url: base.appendingPathComponent("api/delete"))
            request.httpMethod = "DELETE"
            request.httpBody = try JSONSerialization.data(withJSONObject: ["model": LocalModel.name])
            _ = try await URLSession.shared.data(for: request)
            state = .modelMissing
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func installRuntime() async throws {
        appendLog("Installing the Ollaya runtime into \(installPrefix.path)")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "curl -fsSL https://ollaya.dev/install.sh | sh"]
        var env = ProcessInfo.processInfo.environment
        env["OLLAYA_INSTALL_DIR"] = installPrefix.path
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
        process.environment = env
        let status = try await runStreaming(process)
        guard status == 0, binaryURL != nil else {
            throw LocalModelError.message("The Ollaya installer exited with status \(status). See the log for details.")
        }
        appendLog("Ollaya installed.")
    }

    private func pullModel() async throws {
        appendLog("Downloading \(LocalModel.name) into \(modelStore.path)…")
        state = .pullingModel(status: "pulling manifest", completed: 0, total: LocalModel.approximateBytes)
        var request = URLRequest(url: base.appendingPathComponent("api/pull"))
        request.httpMethod = "POST"
        request.timeoutInterval = 60 * 60 * 6
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": LocalModel.name])
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw LocalModelError.message("The model registry refused the download (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)).")
        }
        var layers: [String: (Int64, Int64)] = [:]
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard let data = line.data(using: .utf8),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let error = json["error"] as? String { throw LocalModelError.message(error) }
            let status = json["status"] as? String ?? ""
            if let digest = json["digest"] as? String {
                let total = (json["total"] as? NSNumber)?.int64Value ?? 0
                let done = (json["completed"] as? NSNumber)?.int64Value ?? 0
                if layers[digest] == nil { appendLog(status) }
                layers[digest] = (done, total)
            } else {
                appendLog(status)
            }
            let completed = layers.values.reduce(0) { $0 + $1.0 }
            let total = max(layers.values.reduce(0) { $0 + $1.1 }, LocalModel.approximateBytes)
            state = .pullingModel(status: status, completed: completed, total: total)
            if status == "success" { return }
        }
        throw LocalModelError.message("The download ended before it finished. Try again to resume it.")
    }

    // MARK: Server

    /// Starts `ollaya serve` unless a server is already listening.
    func ensureServer() async throws {
        if await isServerAlive() { return }
        guard let binary = binaryURL else { throw LocalModelError.message("The Ollaya runtime is not installed.") }
        appendLog("Starting \(binary.path) serve")
        let process = Process()
        process.executableURL = binary
        process.arguments = ["serve"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        serverProcess = process
        for _ in 0..<60 {
            try await Task.sleep(for: .milliseconds(250))
            if await isServerAlive() { return }
        }
        throw LocalModelError.message("Ollaya did not start within 15 seconds.")
    }

    /// Stops the server if FrameFold started it.
    func stopServer() {
        serverProcess?.terminate()
        serverProcess = nil
    }

    func isServerAlive() async -> Bool {
        var request = URLRequest(url: base)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 1
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    private func hasModel() async -> Bool {
        guard let (data, _) = try? await URLSession.shared.data(from: base.appendingPathComponent("api/tags")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else { return false }
        return models.contains { ($0["name"] as? String).map(LocalModel.matches) ?? false }
    }

    // MARK: Decide

    struct Decision {
        var label: String
        var confidence: Double
    }

    /// Asks the model which of `categories` fits the photo in `png`.
    func decide(state description: String, png: Data?, categories: [PhotoCategory]) async throws -> Decision {
        var criteria: [String: String] = [:]
        for category in categories.prefix(LocalModel.maxOptions) { criteria[category.name] = category.detail }
        var body: [String: Any] = [
            "model": LocalModel.name,
            "state": description,
            "questions": [
                "category": [
                    "type": "choice",
                    "instructions": "You are sorting a personal photo library. Choose the one category that best describes what this photo shows.",
                    "criteria": criteria,
                ],
            ],
            "keep_alive": "5m",
        ]
        if let png { body["images"] = [png.base64EncodedString()] }
        var request = URLRequest(url: base.appendingPathComponent("api/decide"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 300
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw LocalModelError.message(json["error"] as? String ?? "\(LocalModel.displayName) returned HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0).")
        }
        guard let answers = json["answers"] as? [String: Any],
              let answer = answers["category"] as? [String: Any],
              let label = answer["choice"] as? String else {
            throw LocalModelError.message("\(LocalModel.displayName)'s answer had no category.")
        }
        return Decision(label: label, confidence: (answer["confidence"] as? NSNumber)?.doubleValue ?? 0)
    }

    /// Loads the model ahead of a run so the first photo doesn't pay for it.
    func load() async throws {
        try await ensureServer()
        var request = URLRequest(url: base.appendingPathComponent("api/decide"))
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": LocalModel.name, "keep_alive": "10m"])
        let (data, response) = try await URLSession.shared.data(for: request)
        if (response as? HTTPURLResponse)?.statusCode != 200 {
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            throw LocalModelError.message(json?["error"] as? String ?? "Could not load \(LocalModel.displayName).")
        }
    }

    /// Frees the model's memory.
    func unload() async {
        guard await isServerAlive() else { return }
        var request = URLRequest(url: base.appendingPathComponent("api/decide"))
        request.httpMethod = "POST"
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["model": LocalModel.name, "keep_alive": 0])
        _ = try? await URLSession.shared.data(for: request)
    }

    // MARK: Helpers

    private func appendLog(_ line: String) {
        log.append(line)
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }

    private func runStreaming(_ process: Process) async throws -> Int32 {
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            let lines = text.split(whereSeparator: \.isNewline).map(String.init)
            Task { @MainActor in lines.forEach { self?.appendLog($0) } }
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                process.terminationHandler = { p in
                    pipe.fileHandleForReading.readabilityHandler = nil
                    cont.resume(returning: p.terminationStatus)
                }
                do { try process.run() } catch { cont.resume(throwing: error) }
            }
        } onCancel: {
            process.terminate()
        }
    }
}

enum LocalModelError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let m): return m }
    }
}
