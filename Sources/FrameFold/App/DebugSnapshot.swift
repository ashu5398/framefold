#if DEBUG
import AppKit
import ImageCaptureCore
import ImageIO

/// Debug builds only: `FRAMEFOLD_SNAPSHOT=/path/prefix` writes PNGs of the main window every few
/// seconds, so UI can be checked without screen-recording permission.
enum DebugSnapshot {
    /// `FRAMEFOLD_DEMO=1`: screenshot mode. Shows a connected iPhone, keeps the library's own
    /// device and iCloud flags, and never touches a real device or the Photos library.
    static var isDemo: Bool { ProcessInfo.processInfo.environment["FRAMEFOLD_DEMO"] != nil }

    /// Window size (`FRAMEFOLD_WINDOW=1440x900`) and appearance (`FRAMEFOLD_APPEARANCE=light|dark`).
    @MainActor static func applyWindowOverrides() {
        let env = ProcessInfo.processInfo.environment
        if let mode = env["FRAMEFOLD_APPEARANCE"] {
            NSApp.appearance = NSAppearance(named: mode == "light" ? .aqua : .darkAqua)
        }
        if let size = env["FRAMEFOLD_WINDOW"]?.split(separator: "x").compactMap({ Double($0) }), size.count == 2,
           let window = NSApp.windows.first(where: { $0.isVisible }) {
            window.setFrame(NSRect(x: 80, y: 80, width: size[0], height: size[1]), display: true)
        }
    }

    nonisolated(unsafe) private static var activity: NSObjectProtocol?
    nonisolated(unsafe) private static var mergedTarget: String?
    nonisolated(unsafe) private static var mergedSources: [String] = []

    /// Scripted test runs can read a real iPhone and Photos library but must never delete.
    /// Appends a line to `<prefix>-log.txt` during scripted runs.
    static func log(_ line: String) {
        guard let prefix = ProcessInfo.processInfo.environment["FRAMEFOLD_SNAPSHOT"] else { return }
        let url = URL(fileURLWithPath: prefix + "-log.txt")
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }

    static var blocksDestructiveActions: Bool {
        ProcessInfo.processInfo.environment["FRAMEFOLD_SNAPSHOT"] != nil
    }

    /// `FRAMEFOLD_ACTIONS="years;duplicates;selectdups;delete"` runs one step before each snapshot.
    @MainActor static func startIfRequested(state: AppState) {
        guard let prefix = ProcessInfo.processInfo.environment["FRAMEFOLD_SNAPSHOT"] else { return }
        var actions = (ProcessInfo.processInfo.environment["FRAMEFOLD_ACTIONS"] ?? "").split(separator: ";").map(String.init)
        startHangDetector()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { applyWindowOverrides() }
        var n = 0
        // Keep App Nap from throttling the timer while the window is in the background.
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: "Scripted snapshots")
        let timer = Timer(timeInterval: 3, repeats: true) { _ in
            MainActor.assumeIsolated {
                if !actions.isEmpty {
                    let action = actions.removeFirst()
                    log("action \(action)")
                    run(action, state: state)
                }
                let capture = ProcessInfo.processInfo.environment["FRAMEFOLD_NO_PNG"] == nil
                for (w, window) in NSApp.windows.filter({ capture && $0.isVisible }).enumerated() {
                    guard let view = window.contentView?.superview, let layer = view.layer else { continue }
                    let scale = window.backingScaleFactor
                    let size = view.bounds.size
                    guard let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                              bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
                    ctx.scaleBy(x: scale, y: scale)
                    if view.isFlipped {
                        ctx.translateBy(x: 0, y: size.height)
                        ctx.scaleBy(x: 1, y: -1)
                    }
                    layer.render(in: ctx)
                    guard let image = ctx.makeImage() else { continue }
                    let rep = NSBitmapImageRep(cgImage: image)
                    let name = w == 0 ? "\(prefix)-\(n).png" : "\(prefix)-\(n)-w\(w).png"
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: name))
                    if w == 0 { try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(prefix)-latest.png")) }
                }
                n += 1
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Logs every main-thread stall longer than 100 ms.
    private static func startHangDetector() {
        Thread.detachNewThread {
            while true {
                let sent = Date()
                let semaphore = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { semaphore.signal() }
                semaphore.wait()
                let stall = Date().timeIntervalSince(sent)
                if stall > 0.1 { log(String(format: "HANG %.0f ms", stall * 1000)) }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
    }

    @MainActor private static func run(_ action: String, state: AppState) {
        switch action {
        case "years": state.scale = .years
        case "months": state.scale = .months
        case "all": state.scale = .all
        case "zoomout": state.zoomOut()
        case "duplicates": state.findDuplicates()
        case "selectdups":
            state.selectDuplicates()
            log("range \(state.duplicateRange.title): groups shown \(state.sections.count), selected \(state.selection.count)")
        case "range30": state.duplicateRange = .lastDays(30)
        case "rangeall": state.duplicateRange = .allTime
        case "select3": state.selection = Set(state.visibleItems.prefix(3).map(\.id))
        case "delete": state.requestDelete(state.selection)
        case "canceldelete": state.pendingDelete = nil
        case "model": state.showModelSheet = true
        case "closemodel": state.showModelSheet = false
        case "viewer": state.viewerID = state.visibleItems.first?.id
        case "closeviewer": state.viewerID = nil
        case "shortcuts": state.showShortcuts = true
        case "move": state.move(state.selection, to: "Pets & Animals")
        case "animals": state.sidebar = .category("Pets & Animals")
        case "allphotos": state.sidebar = .allPhotos
        case "selectall": state.selection = Set(state.visibleItems.map(\.id))
        case "deletelocal":
            let ids = Array(state.selection.prefix(3000))
            log("deleting \(ids.count) from FrameFold")
            state.performDelete(ids, mode: .frameFoldOnly)
        case "zoomin": state.zoomIn()
        case let a where a.hasPrefix("import:"):
            state.importFiles([URL(fileURLWithPath: String(a.dropFirst("import:".count)))])
        case let a where a.hasPrefix("open:"):
            // open:<file name> opens that item in the viewer.
            let name = String(a.dropFirst("open:".count))
            state.viewerID = state.visibleItems.first { $0.fileName == name }?.id
        case let a where a.hasPrefix("select:"):
            let count = Int(a.dropFirst("select:".count)) ?? 3
            state.selection = Set(state.visibleItems.prefix(count).map(\.id))
        case let a where a.hasPrefix("category:"):
            state.sidebar = .category(String(a.dropFirst("category:".count)))
        case "info": UserDefaults.standard.set(true, forKey: "viewerInfo")
        case "window": applyWindowOverrides()
        case "categorizeall":
            let start = Date()
            state.categorize(.all)
            Task { @MainActor in
                while !state.categorizer.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
                while state.categorizer.isRunning { try? await Task.sleep(for: .milliseconds(200)) }
                let seconds = Date().timeIntervalSince(start)
                log(String(format: "categorised %d in %.1fs (%.2fs each) error=%@", state.categorizer.done, seconds,
                           seconds / Double(max(state.categorizer.done, 1)), state.categorizer.lastError ?? "none"))
            }
        case "notperson":
            if let person = state.library.people.max(by: { $0.faceKeys.count < $1.faceKeys.count }), let key = person.faceKeys.first {
                let photo = String(key[..<(key.lastIndex(of: "_") ?? key.endIndex)])
                state.sidebar = .person(person.id)
                state.removeFromPerson([photo], person: person.id)
                log("rejected \(photo) from \(person.name) (\(person.faceKeys.count) faces)")
            }
        case "mergesmall":
            // Merge the 3rd and 4th largest people into the largest, as a user would.
            let ranked = state.library.people.sorted { $0.faceKeys.count > $1.faceKeys.count }
            if ranked.count >= 4 {
                for source in ranked[2...3] { state.library.mergePerson(source.id, into: ranked[0].id) }
                log("merged \(ranked[2].faceKeys.count)+\(ranked[3].faceKeys.count) faces into \(ranked[0].name) (\(ranked[0].faceKeys.count)); people now \(state.library.people.count)")
                mergedTarget = ranked[0].id
                mergedSources = [ranked[2].faceKeys, ranked[3].faceKeys].flatMap { $0 }
            }
        case "checkmerge":
            if let target = state.library.person(mergedTarget ?? "") {
                let keys = Set(target.faceKeys)
                let kept = mergedSources.filter { keys.contains($0) }.count
                log("after regroup: \(target.name) has \(target.faceKeys.count) faces; merged faces still with it: \(kept)/\(mergedSources.count); people \(state.library.people.count)")
            }
        case "regroup":
            state.analysis.clusterPeople(force: true)
        case "checkperson":
            for person in state.library.people where !person.rejectedPhotoIDs.isEmpty {
                let photos = Set(person.faceKeys.map { String($0[..<($0.lastIndex(of: "_") ?? $0.endIndex)]) })
                log("check \(person.name): \(person.faceKeys.count) faces, rejected still present: \(!photos.isDisjoint(with: person.rejectedPhotoIDs))")
            }
        case "collapsefirst": if let id = state.sections.first?.id { state.toggleSection(id, all: false) }
        case "collapseall": state.collapseAll()
        case "expandall": state.expandAll()
        default: break
        }
    }
}
#endif
