import Accelerate
import Foundation
import Vision

/// Runs Vision over synced photos in the background, groups faces into people and finds duplicates.
@MainActor
final class AnalysisEngine: ObservableObject {
    @Published private(set) var isAnalyzing = false
    @Published private(set) var analyzed = 0
    @Published private(set) var total = 0
    @Published private(set) var duplicateGroups: [[String]] = []
    @Published private(set) var isFindingDuplicates = false

    /// Feature-print distance under which two photos count as near-duplicates.
    @Published var duplicateThreshold: Double = UserDefaults.standard.object(forKey: "duplicateThreshold") as? Double ?? 0.32 {
        didSet { UserDefaults.standard.set(duplicateThreshold, forKey: "duplicateThreshold") }
    }
    /// Cosine similarity of AuraFace embeddings from which two faces count as the same person.
    @Published var faceSimilarity: Double = UserDefaults.standard.object(forKey: "faceSimilarity") as? Double ?? 0.45 {
        didSet { UserDefaults.standard.set(faceSimilarity, forKey: "faceSimilarity") }
    }
    @Published private(set) var isGroupingPeople = false

    private let library: LibraryStore
    private var task: Task<Void, Never>?

    init(library: LibraryStore) {
        self.library = library
    }

    // MARK: Analysis

    func analyzePending() {
        guard task == nil else { return }
        let pending = library.items.filter { $0.hasThumbnail && !$0.analyzed && !$0.isCompanion }
        // Photos analysed before the current face pipeline only need their faces redone.
        let facesOnly = library.items.filter {
            $0.hasThumbnail && $0.analyzed && !$0.isCompanion && $0.faceVersion < FaceRecognizer.pipelineVersion
        }
        guard !pending.isEmpty || (!facesOnly.isEmpty && FaceRecognizer.shared.isAvailable) else {
            clusterPeople()
            return
        }
        isAnalyzing = true
        analyzed = 0
        total = pending.count + (FaceRecognizer.shared.isAvailable ? facesOnly.count : 0)
        task = Task { [weak self] in
            await self?.run(pending, facesOnly: false)
            if FaceRecognizer.shared.isAvailable { await self?.run(facesOnly, facesOnly: true) }
            self?.task = nil
            self?.isAnalyzing = false
            self?.clusterPeople()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        isAnalyzing = false
    }

    private struct Outcome: Sendable {
        var labels: [String]?
        var text: String?
        var faceCount: Int
    }

    private func run(_ items: [PhotoItem], facesOnly: Bool) async {
        let facesDir = library.facesDir
        for chunk in stride(from: 0, to: items.count, by: 8).map({ Array(items[$0..<min($0 + 8, items.count)]) }) {
            if Task.isCancelled { return }
            let jobs: [(id: String, url: URL, printURL: URL, oldFaces: Int)] = chunk.compactMap { item in
                // Thumbnails are enough for labels, faces and feature prints, so the phone isn't touched.
                library.analysisURL(for: item).map { (item.id, $0, library.featurePrintURL(for: item.id), item.faceCount) }
            }
            let results = await withTaskGroup(of: (String, Outcome?).self) { group in
                for job in jobs {
                    group.addTask(priority: .utility) {
                        var outcome: Outcome?
                        var faces: [VisionAnalyzer.Face] = []
                        if facesOnly {
                            if let found = await VisionAnalyzer.faces(url: job.url) {
                                faces = found
                                outcome = Outcome(labels: nil, text: nil, faceCount: found.count)
                            }
                        } else if let result = await VisionAnalyzer.analyze(url: job.url) {
                            try? result.featurePrint?.write(to: job.printURL)
                            faces = result.faces
                            outcome = Outcome(labels: result.labels.map(\.0), text: result.text, faceCount: result.faces.count)
                        }
                        guard outcome != nil else { return (job.id, nil) }
                        // Replace any faces from an earlier pipeline.
                        for n in 0..<max(job.oldFaces, faces.count) {
                            for ext in ["jpg", "fp", "emb"] {
                                try? FileManager.default.removeItem(at: facesDir.appendingPathComponent("\(job.id)_\(n).\(ext)"))
                            }
                        }
                        for (n, face) in faces.enumerated() {
                            MediaTools.writeJPEG(face.crop, to: facesDir.appendingPathComponent("\(job.id)_\(n).jpg"), quality: 0.85)
                            try? face.embedding.write(to: facesDir.appendingPathComponent("\(job.id)_\(n).emb"))
                        }
                        return (job.id, outcome)
                    }
                }
                var out: [(String, Outcome?)] = []
                for await r in group { out.append(r) }
                return out
            }
            let byID = Dictionary(results.map { ($0.0, $0.1) }, uniquingKeysWith: { a, _ in a })
            let version = FaceRecognizer.shared.isAvailable ? FaceRecognizer.pipelineVersion : 0
            library.updateAll(byID.keys) { item in
                item.analyzed = true
                guard let outcome = byID[item.id] ?? nil else { return }
                if let labels = outcome.labels {
                    item.labels = labels
                    item.recognizedText = outcome.text
                }
                item.faceCount = outcome.faceCount
                item.faceVersion = version
            }
            analyzed += chunk.count
        }
    }

    // MARK: People

    /// Groups every face in the library into people, in the background. Groups that match an
    /// earlier person keep its id, name and hidden state.
    func clusterPeople(force: Bool = false) {
        guard !isGroupingPeople else { return }
        var keys: [String] = []
        var photoOf: [String: String] = [:]
        for item in library.items where item.faceCount > 0 && item.faceVersion == FaceRecognizer.pipelineVersion && !item.isCompanion {
            for n in 0..<item.faceCount {
                let key = "\(item.id)_\(n)"
                keys.append(key)
                photoOf[key] = item.id
            }
        }
        let known = Set(library.people.flatMap(\.faceKeys))
        // Nothing new and nothing to regroup.
        guard force || keys.contains(where: { !known.contains($0) }) || library.people.contains(where: { $0.faceKeys.contains { !photoOf.keys.contains($0) } }) else { return }

        let previous = library.people
        let facesDir = library.facesDir
        let threshold = Float(faceSimilarity)
        isGroupingPeople = true
        Task {
            let people = await Task.detached(priority: .utility) {
                Self.group(keys, facesDir: facesDir, threshold: threshold, previous: previous)
            }.value
            isGroupingPeople = false
            apply(people)
        }
    }

    private func apply(_ people: [Person]) {
        var personsByPhoto: [String: Set<String>] = [:]
        for person in people {
            for key in person.faceKeys {
                let photoID = String(key[..<(key.lastIndex(of: "_") ?? key.endIndex)])
                personsByPhoto[photoID, default: []].insert(person.id)
            }
        }
        library.setPeople(people)
        library.mutateEach { item in
            item.personIDs = Array(personsByPhoto[item.id] ?? [])
        }
    }

    /// Clusters face embeddings by cosine similarity, as dlib does for faces:
    /// 1. Chinese Whispers on a graph linking each face to its closest faces above `threshold`.
    /// 2. Merges groups whose centres agree strongly; one person's photos with and without
    ///    sunglasses or a beard often form separate groups first.
    /// 3. Attaches faces left on their own to a group they clearly match.
    nonisolated static func group(_ keys: [String], facesDir: URL, threshold: Float, previous: [Person]) -> [Person] {
        let dim = FaceRecognizer.embeddingLength
        var matrix: [Float] = []
        var faceKeys: [String] = []
        for key in keys {
            guard let data = try? Data(contentsOf: facesDir.appendingPathComponent("\(key).emb")),
                  let vector = FaceRecognizer.decode(data) else { continue }
            matrix += vector
            faceKeys.append(key)
        }
        let n = faceKeys.count
        guard n > 0 else { return [] }

        // Each face's closest faces, from similarities computed a block of rows at a time.
        let neighbours = 12
        var graph: [[(Int, Float)]] = Array(repeating: [], count: n)
        let block = 512
        var sims = [Float](repeating: 0, count: block * n)
        for start in stride(from: 0, to: n, by: block) {
            let rows = min(block, n - start)
            matrix.withUnsafeBufferPointer { all in
                cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans, Int32(rows), Int32(n), Int32(dim),
                            1, all.baseAddress! + start * dim, Int32(dim), all.baseAddress!, Int32(dim), 0, &sims, Int32(n))
            }
            for r in 0..<rows {
                let i = start + r
                var best: [(Int, Float)] = []
                for j in 0..<n where j != i {
                    let sim = sims[r * n + j]
                    guard sim >= threshold else { continue }
                    if best.count < neighbours {
                        best.append((j, sim))
                        if best.count == neighbours { best.sort { $0.1 > $1.1 } }
                    } else if sim > best[neighbours - 1].1 {
                        best[neighbours - 1] = (j, sim)
                        best.sort { $0.1 > $1.1 }
                    }
                }
                graph[i] = best
            }
        }

        // 1. Chinese Whispers, with a fixed seed so regrouping is repeatable.
        var labels = Array(0..<n)
        var rng = SplitMix(seed: 42)
        var order = Array(0..<n)
        for _ in 0..<25 {
            order.shuffle(using: &rng)
            var changed = false
            for i in order where !graph[i].isEmpty {
                var score: [Int: Float] = [:]
                for (j, w) in graph[i] { score[labels[j], default: 0] += w }
                if let best = score.max(by: { $0.value < $1.value })?.key, best != labels[i] {
                    labels[i] = best
                    changed = true
                }
            }
            if !changed { break }
        }
        var groups = Array(Dictionary(grouping: 0..<n, by: { labels[$0] }).values)

        func centre(_ members: [Int]) -> [Float] {
            var sum = [Float](repeating: 0, count: dim)
            for m in members {
                matrix.withUnsafeBufferPointer { all in
                    vDSP_vadd(sum, 1, all.baseAddress! + m * dim, 1, &sum, 1, vDSP_Length(dim))
                }
            }
            var norm: Float = 0
            vDSP_svesq(sum, 1, &norm, vDSP_Length(dim))
            norm = sqrt(norm)
            if norm > 0 { vDSP_vsdiv(sum, 1, &norm, &sum, 1, vDSP_Length(dim)) }
            return sum
        }

        // 2. Merge the most alike pair of groups until no centres agree closely enough.
        let mergeThreshold = threshold + 0.15
        var centres = groups.map(centre)
        while true {
            var best: (Float, Int, Int)?
            for a in 0..<groups.count where groups[a].count > 1 {
                for b in (a + 1)..<groups.count where groups[b].count > 1 {
                    let sim = FaceRecognizer.cosine(centres[a], centres[b])
                    if sim >= mergeThreshold, sim > (best?.0 ?? -1) { best = (sim, a, b) }
                }
            }
            guard let (_, a, b) = best else { break }
            groups[a] += groups[b]
            centres[a] = centre(groups[a])
            groups.remove(at: b)
            centres.remove(at: b)
        }

        // 3. Attach lone faces to the group they clearly belong to.
        let attachThreshold = threshold + 0.05
        let multi = groups.indices.filter { groups[$0].count > 1 }
        for i in groups.indices where groups[i].count == 1 {
            let face = groups[i][0]
            let vector = Array(matrix[face * dim..<(face + 1) * dim])
            if let (sim, target) = multi.map({ (FaceRecognizer.cosine(vector, centres[$0]), $0) }).max(by: { $0.0 < $1.0 }),
               sim >= attachThreshold {
                groups[target].append(face)
                groups[i] = []
            }
        }
        let finalGroups = groups.filter { !$0.isEmpty }.map { members in members.map { faceKeys[$0] } }

        // Carry ids, names, hidden flags and corrections over from earlier people with the most
        // photos in common. A person the user named or merged can take in several new groups:
        // the user said those faces are one person, so they stay one person.
        func photo(_ key: String) -> String { String(key[..<(key.lastIndex(of: "_") ?? key.endIndex)]) }
        let currentKeys = Set(finalGroups.joined())
        // Match on exact faces; only people whose faces all predate the current face pipeline
        // (keys no longer present) fall back to matching on photos.
        let previousFaces = previous.map { person -> (person: Person, keys: Set<String>, byPhoto: Bool) in
            let keys = Set(person.faceKeys)
            return keys.isDisjoint(with: currentKeys) ? (person, Set(keys.map(photo)), true) : (person, keys, false)
        }
        var byID: [String: Person] = [:]
        var personOrder: [String] = []
        for keys in finalGroups.sorted(by: { $0.count > $1.count }) {
            let faceSet = Set(keys)
            let photos = Set(keys.map(photo))
            let match = previousFaces
                .filter { $0.person.isNamed || $0.person.isUserMerged || byID[$0.person.id] == nil }
                .map { (person: $0.person, overlap: $0.byPhoto ? $0.keys.intersection(photos).count : $0.keys.intersection(faceSet).count) }
                .max { $0.overlap < $1.overlap }
            var person: Person
            if let match, match.overlap >= max(1, keys.count / 3) {
                if var existing = byID[match.person.id] {
                    existing.faceKeys += keys
                    person = existing
                } else {
                    person = Person(id: match.person.id, name: "", faceKeys: keys)
                    person.isHidden = match.person.isHidden
                    person.isUserMerged = match.person.isUserMerged
                    person.rejectedPhotoIDs = match.person.rejectedPhotoIDs
                    if match.person.isNamed {
                        person.name = match.person.name
                        person.isNamed = true
                    }
                    personOrder.append(person.id)
                }
            } else {
                person = Person(id: UUID().uuidString, name: "", faceKeys: keys)
                personOrder.append(person.id)
            }
            // Corrections the user made stay corrected.
            let rejected = Set(person.rejectedPhotoIDs)
            person.faceKeys.removeAll { rejected.contains(photo($0)) }
            person.avatarPath = person.faceKeys.first.map { "\($0).jpg" }
            byID[person.id] = person
        }
        var people = personOrder.compactMap { byID[$0] }.filter { !$0.faceKeys.isEmpty }
        people.sort { $0.faceKeys.count > $1.faceKeys.count }
        var counter = 1
        for i in people.indices where !people[i].isNamed {
            people[i].name = "Person \(counter)"
            counter += 1
        }
        return people
    }

    /// Small seeded generator so grouping gives the same answer every run.
    struct SplitMix: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    // MARK: Duplicates

    func findDuplicates() async {
        isFindingDuplicates = true
        defer { isFindingDuplicates = false }
        let items = library.items
            .filter { $0.hasThumbnail && !$0.isCompanion }
            .sorted { $0.captureDate < $1.captureDate }
        let printURLs = items.map { library.featurePrintURL(for: $0.id) }
        let threshold = Float(duplicateThreshold)
        let groups = await Task.detached(priority: .userInitiated) {
            Self.groupDuplicates(items: items, printURLs: printURLs, threshold: threshold)
        }.value
        duplicateGroups = groups
    }

    func reset() {
        cancel()
        duplicateGroups = []
    }

    func forgetDuplicates(_ removed: Set<String>) {
        duplicateGroups = duplicateGroups
            .map { $0.filter { !removed.contains($0) } }
            .filter { $0.count > 1 }
    }

    nonisolated private static func groupDuplicates(items: [PhotoItem], printURLs: [URL], threshold: Float) -> [[String]] {
        var parent = Array(items.indices)
        func find(_ i: Int) -> Int {
            var i = i
            while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }
            return i
        }
        func union(_ a: Int, _ b: Int) { parent[find(a)] = find(b) }

        // Identical files anywhere in the library: same hash, or for files still on the phone,
        // same size and dimensions.
        var byKey: [String: Int] = [:]
        for (i, item) in items.enumerated() where item.fileSize > 0 {
            if let j = byKey[item.exactKey] { union(i, j) } else { byKey[item.exactKey] = i }
        }

        // Visually near-identical photos: compare each photo with the ones taken shortly before it.
        let prints = printURLs.map { (try? Data(contentsOf: $0)).flatMap(VisionAnalyzer.unarchive) }
        let window = 24
        for i in items.indices where items[i].kind == .photo {
            guard let a = prints[i] else { continue }
            for j in max(0, i - window)..<i where items[j].kind == .photo {
                guard let b = prints[j] else { continue }
                if let d = VisionAnalyzer.distance(a, b), d < threshold { union(i, j) }
            }
        }

        var groups: [Int: [Int]] = [:]
        for i in items.indices { groups[find(i), default: []].append(i) }
        return groups.values
            .filter { $0.count > 1 }
            .map { members in
                // Best copy first: most pixels, then largest file.
                members.sorted {
                    (items[$0].pixelCount, items[$0].fileSize) > (items[$1].pixelCount, items[$1].fileSize)
                }
            }
            .sorted { items[$0[0]].captureDate > items[$1[0]].captureDate }
            .map { $0.map { items[$0].id } }
    }
}
