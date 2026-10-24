import Foundation

/// Sorts photos into categories: Photos app smart albums first, then the local model for the rest.
@MainActor
final class Categorizer: ObservableObject {
    enum Scope: Equatable {
        case uncategorized
        case all
        case items(Set<String>)
    }

    @Published private(set) var isRunning = false
    @Published private(set) var done = 0
    @Published private(set) var total = 0
    @Published private(set) var currentID: String?
    @Published private(set) var lastError: String?
    private var startedAt = Date()
    private var doneAtStart = 0

    /// Estimated time left, once enough photos are done to judge the pace.
    var remaining: TimeInterval? {
        let finished = done - doneAtStart
        guard isRunning, finished >= 5 else { return nil }
        let perItem = Date().timeIntervalSince(startedAt) / Double(finished)
        return perItem * Double(total - done)
    }

    var onFinished: ((Int) -> Void)?

    private let library: LibraryStore
    private let model: LocalModelService
    private var task: Task<Void, Never>?

    /// Photos smart albums that already say what a photo is.
    private let albumCategories = ["Screenshots": "Screenshots", "Selfies": "Selfies"]

    init(library: LibraryStore, model: LocalModelService) {
        self.library = library
        self.model = model
    }

    func targets(for scope: Scope) -> [PhotoItem] {
        library.items.filter { item in
            guard item.hasThumbnail, !item.isCompanion else { return false }
            switch scope {
            case .uncategorized: return item.category == nil
            case .all: return item.categorySource != .manual
            case .items(let ids): return ids.contains(item.id)
            }
        }
    }

    func start(scope: Scope) {
        guard !isRunning else { return }
        let items = targets(for: scope)
        guard !items.isEmpty else { return }
        isRunning = true
        lastError = nil
        done = 0
        total = items.count
        startedAt = Date()
        doneAtStart = 0
        task = Task {
            await run(items)
            isRunning = false
            currentID = nil
            await model.unload()
            model.stopServer()
            onFinished?(done)
        }
    }

    func cancel() {
        task?.cancel()
    }

    private func run(_ items: [PhotoItem]) async {
        let categories = Array(library.categories.prefix(LocalModel.maxOptions))
        let names = Set(categories.map(\.name))

        // Cases that don't need the model: Photos smart albums and obvious screenshots or
        // documents. Each model call costs about a second, so these are worth skipping.
        var forModel: [PhotoItem] = []
        for item in items {
            if let category = Self.shortcut(for: item, albumCategories: albumCategories), names.contains(category.name) {
                library.update(item.id) {
                    $0.category = category.name
                    $0.categorySource = category.source
                    $0.categoryConfidence = 1
                }
                done += 1
            } else {
                forModel.append(item)
            }
        }
        guard !forModel.isEmpty else { return }
        // Pace is measured over model calls only; shortcuts are instant.
        startedAt = Date()
        doneAtStart = done

        do {
            try await model.load()
        } catch {
            lastError = error.localizedDescription
            return
        }

        // While the model answers for one photo, the next one is prepared.
        var next: Task<Prepared, Never>? = prepare(forModel[0])
        for (i, item) in forModel.enumerated() {
            if Task.isCancelled { next?.cancel(); return }
            currentID = item.id
            guard let prepared = await next?.value else { break }
            next = i + 1 < forModel.count ? prepare(forModel[i + 1]) : nil
            if let analysis = prepared.analysis {
                library.update(item.id) {
                    $0.labels = analysis.labels
                    $0.recognizedText = analysis.text
                    $0.faceCount = analysis.faceCount
                    $0.analyzed = true
                }
            }
            let current = library.item(item.id) ?? item
            if let category = Self.shortcut(for: current, albumCategories: albumCategories), names.contains(category.name) {
                library.update(item.id) {
                    $0.category = category.name
                    $0.categorySource = category.source
                    $0.categoryConfidence = 1
                }
                done += 1
                continue
            }
            do {
                // The model looks at the photo, so a short state is enough, and much faster than a
                // long description (measured).
                let state = "A photo from an iPhone camera roll."
                let decision = try await model.decide(state: state, png: prepared.png, categories: categories)
                guard names.contains(decision.label) else { continue }
                library.update(item.id) {
                    $0.category = decision.label
                    $0.categorySource = .model
                    $0.categoryConfidence = decision.confidence
                }
            } catch {
                lastError = error.localizedDescription
                next?.cancel()
                return
            }
            done += 1
        }
    }

    private struct Prepared: Sendable {
        struct Analysis: Sendable {
            var labels: [String]
            var text: String?
            var faceCount: Int
        }
        var analysis: Analysis?
        var png: Data?
    }

    /// Vision analysis (if missing) and the image for the model, off the main thread.
    private func prepare(_ item: PhotoItem) -> Task<Prepared, Never> {
        let analysisURL = item.analyzed ? nil : library.analysisURL(for: item)
        let thumbnail: URL? = library.thumbnailURL(for: item.id)
        return Task.detached(priority: .userInitiated) {
            var prepared = Prepared()
            if let analysisURL, let result = await VisionAnalyzer.analyze(url: analysisURL) {
                prepared.analysis = .init(labels: result.labels.map(\.0), text: result.text, faceCount: result.faces.count)
            }
            // Image size barely changes the model's time (measured), so keep it modest.
            if let thumbnail { prepared.png = MediaTools.pngData(contentsOf: thumbnail, maxPixel: 384) }
            return prepared
        }
    }

    /// Categories that are certain without the model.
    private static func shortcut(for item: PhotoItem, albumCategories: [String: String]) -> (name: String, source: CategorySource)? {
        if let album = item.albums.first(where: { albumCategories[$0] != nil }), let category = albumCategories[album] {
            return (category, .photos)
        }
        // The iPhone saves screenshots, and practically nothing else, as PNG.
        if !item.isVideo, (item.fileName as NSString).pathExtension.uppercased() == "PNG" {
            return ("Screenshots", .model)
        }
        // A page of text with a document-like scene is a document.
        let documentLabels: Set<String> = ["document", "text", "receipt", "paper", "printed page", "handwriting", "menu"]
        if (item.recognizedText?.count ?? 0) >= 150, item.labels.prefix(4).contains(where: { documentLabels.contains($0) }) {
            return ("Documents", .model)
        }
        return nil
    }
}
