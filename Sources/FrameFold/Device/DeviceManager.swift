import Foundation
import ImageCaptureCore

/// Finds iPhones connected over USB and exposes their camera roll through ImageCaptureCore.
@MainActor
final class DeviceManager: NSObject, ObservableObject {
    enum Status: Equatable {
        case idle
        case connecting(String)
        /// The phone is locked or has not trusted this Mac yet.
        case locked(String)
        case loadingCatalog(String, Int)
        case ready(String)
        case failed(String)
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var files: [ICCameraFile] = []
    @Published private(set) var canDelete = false
    /// Progress of a delete on the phone, 0…1, while one runs.
    @Published private(set) var deleteProgress: Double?

    private var refreshTask: Task<Void, Never>?
    private var progressObservation: NSKeyValueObservation?

    /// Called once the device has reported its complete catalogue.
    var onCatalogReady: (() -> Void)?
    var onDisconnect: (() -> Void)?

    private let browser = ICDeviceBrowser()
    private(set) var camera: ICCameraDevice?

    var deviceName: String? { camera?.name }
    /// Stable identity of the connected phone, so items can be tied to it across connections.
    var deviceID: String? { camera.map { $0.persistentIDString ?? $0.serialNumberString ?? $0.name ?? "iPhone" } }
    var isReady: Bool { if case .ready = status { return true } else { return false } }

    override init() {
        super.init()
        browser.delegate = self
        let mask = ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue: mask)!
    }

    func start() {
        browser.start()
    }

    func reconnect() {
        guard let camera else { return }
        if camera.hasOpenSession {
            refreshFiles()
        } else {
            status = .connecting(camera.name ?? "iPhone")
            camera.requestOpenSession()
        }
    }

    #if DEBUG
    /// Screenshot mode: looks connected without a device.
    func showDemoDevice() {
        status = .ready("iPhone 17 Pro")
    }
    #endif

    /// Closes and reopens the session so the phone lists its files from scratch.
    func reloadCatalog() {
        guard let camera else { return }
        let name = camera.name ?? "iPhone"
        refreshTask?.cancel()
        files = []
        status = .loadingCatalog(name, 0)
        guard camera.hasOpenSession else {
            camera.requestOpenSession()
            return
        }
        camera.requestCloseSession(options: nil) { _ in
            Task { @MainActor in camera.requestOpenSession() }
        }
    }

    // MARK: Async wrappers

    func thumbnailData(for file: ICCameraFile, maxPixel: Int = 400) async -> Data? {
        await withCheckedContinuation { cont in
            file.requestThumbnailData(options: [.imageSourceThumbnailMaxPixelSize: maxPixel]) { data, _ in
                cont.resume(returning: data)
            }
        }
    }

    /// Downloads `file` into `directory` as `name`; returns the saved file's URL.
    func download(_ file: ICCameraFile, to directory: URL, as name: String) async throws -> URL {
        try await withCheckedThrowingContinuation { cont in
            let options: [ICDownloadOption: Any] = [
                .downloadsDirectoryURL: directory,
                .saveAsFilename: name,
                .overwrite: true,
                .sidecarFiles: false,
            ]
            file.requestDownload(options: options) { savedName, error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume(returning: directory.appendingPathComponent(savedName ?? name))
                }
            }
        }
    }

    /// Deletes files from the phone. Returns the files that were deleted.
    func delete(_ files: [ICCameraFile]) async -> (deleted: [ICCameraFile], error: Error?, reasons: [String]) {
        guard let camera, !files.isEmpty else { return ([], nil, []) }
        #if DEBUG
        if DebugSnapshot.blocksDestructiveActions { return ([], nil, []) }
        #endif
        AppLog.info("delete: requesting \(files.count) file(s) on \(camera.name ?? "device"); canDelete=\(canDelete) session=\(camera.hasOpenSession) capabilities=\(camera.capabilities)")
        deleteProgress = 0
        defer {
            deleteProgress = nil
            progressObservation = nil
            // The phone reports each removed file separately; reconcile once at the end.
            scheduleRefresh(after: .milliseconds(300))
        }
        var reasons: [String] = []
        let result: ([ICCameraFile], Error?) = await withCheckedContinuation { cont in
            let progress = camera.requestDeleteFiles(files, deleteFailed: { failures in
                // Why individual files were refused, e.g. read-only.
                let described = failures.map { "\($0.key.rawValue): \($0.value.name ?? "?")" }
                Task { @MainActor in reasons += failures.keys.map(\.rawValue) }
                AppLog.info("delete: refused \(described.joined(separator: ", "))")
            }) { result, error in
                let deleted = (result[.successful] ?? []).compactMap { $0 as? ICCameraFile }
                let failed = (result[.failed] ?? []).count
                AppLog.info("delete: done, \(deleted.count) deleted, \(failed) failed, error=\(error.map { "\($0)" } ?? "none")")
                cont.resume(returning: (deleted, error))
            }
            if progress == nil { AppLog.info("delete: the device returned no progress (request not started)") }
            progressObservation = progress?.observe(\.fractionCompleted) { [weak self] progress, _ in
                let fraction = progress.fractionCompleted
                Task { @MainActor in if self?.deleteProgress != nil { self?.deleteProgress = fraction } }
            }
        }
        // Let refusal callbacks that raced the completion land.
        try? await Task.sleep(for: .milliseconds(50))
        return (result.0, result.1, reasons)
    }

    var isDeleting: Bool { deleteProgress != nil }

    /// One line per file the phone lists, with every flag it reports, to explain files that
    /// FrameFold sees but the Photos app doesn't show.
    private static func writeCatalogueDump(_ files: [ICCameraFile]) {
        let rows = files.map { f -> String in
            func path(_ folder: ICCameraFolder?) -> String {
                guard let folder else { return "" }
                return path(folder.parentFolder) + "/" + (folder.name ?? "?")
            }
            func date(_ d: Date?) -> String { d.map { ISO8601DateFormatter().string(from: $0) } ?? "" }
            let fields: [String] = [
                f.name ?? "", f.originalFilename ?? "", f.createdFilename ?? "", path(f.parentFolder),
                "\(f.fileSize)", "\(f.width)x\(f.height)", date(f.exifCreationDate), date(f.fileCreationDate), date(f.creationDate),
                f.isLocked ? "locked" : "", f.isInTemporaryStore ? "temporary" : "", f.isRaw ? "raw" : "",
                f.wasAddedAfterContentCatalogCompleted ? "added-later" : "",
                f.originatingAssetID ?? "", f.groupUUID ?? "", f.relatedUUID ?? "", f.burstUUID ?? "",
                f.burstPicked ? "burst-picked" : "", f.burstFavorite ? "burst-favorite" : "",
                f.highFramerate ? "slomo" : "", f.timeLapse ? "timelapse" : "", f.firstPicked ? "first-picked" : "",
                (f.sidecarFiles ?? []).compactMap(\.name).joined(separator: "+"), "\(f.ptpObjectHandle)",
            ]
            return fields.map { $0.replacingOccurrences(of: ",", with: ";") }.joined(separator: ",")
        }
        let header = "name,originalFilename,createdFilename,folder,size,dimensions,exifDate,fileDate,itemDate,locked,temporary,raw,addedLater,originatingAssetID,groupUUID,relatedUUID,burstUUID,burstPicked,burstFavorite,slomo,timelapse,firstPicked,sidecars,ptpHandle"
        let text = ([header] + rows).joined(separator: "\n")
        let url = AppLog.directory.appendingPathComponent("catalogue.csv")
        DispatchQueue.global(qos: .utility).async { try? text.write(to: url, atomically: true, encoding: .utf8) }
    }

    /// Coalesces the per-file add and remove events the phone sends into one catalogue refresh.
    private func scheduleRefresh(after delay: Duration = .seconds(1)) {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled, self.isReady, !self.isDeleting else { return }
            self.refreshFiles()
        }
    }

    private func refreshFiles() {
        guard let camera else { return }
        files = (camera.mediaFiles ?? []).compactMap { $0 as? ICCameraFile }
        canDelete = camera.capabilities.contains(ICDeviceCapability.cameraDeviceCanDeleteOneFile.rawValue)
        AppLog.info("device: catalogue \(files.count) files, canDelete=\(canDelete)")
        Self.writeCatalogueDump(files)
        status = .ready(camera.name ?? "iPhone")
        onCatalogReady?()
    }

    fileprivate func attach(_ device: ICCameraDevice) {
        AppLog.info("device: attached \(device.name ?? "?") id=\(device.persistentIDString ?? "-")")
        guard camera == nil else { return }
        camera = device
        device.delegate = self
        status = .connecting(device.name ?? "iPhone")
        device.requestOpenSession()
    }

    fileprivate func detach(_ device: ICDevice) {
        guard device == camera else { return }
        camera = nil
        files = []
        canDelete = false
        status = .idle
        onDisconnect?()
    }
}

extension DeviceManager: ICDeviceBrowserDelegate {
    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard let camera = device as? ICCameraDevice else { return }
        Task { @MainActor in self.attach(camera) }
    }

    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        Task { @MainActor in self.detach(device) }
    }
}

extension DeviceManager: ICCameraDeviceDelegate {
    nonisolated func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        Task { @MainActor in
            if let error {
                self.status = .failed(error.localizedDescription)
            } else if let camera = device as? ICCameraDevice {
                if camera.isAccessRestrictedAppleDevice {
                    self.status = .locked(camera.name ?? "iPhone")
                } else {
                    self.status = .loadingCatalog(camera.name ?? "iPhone", camera.contentCatalogPercentCompleted)
                }
            }
        }
    }

    nonisolated func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {}

    nonisolated func didRemove(_ device: ICDevice) {
        Task { @MainActor in self.detach(device) }
    }

    nonisolated func device(_ device: ICDevice, didEncounterError error: Error?) {
        guard let error else { return }
        Task { @MainActor in self.status = .failed(error.localizedDescription) }
    }

    nonisolated func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {
        Task { @MainActor in
            if case .loadingCatalog(let name, _) = self.status {
                self.status = .loadingCatalog(name, camera.contentCatalogPercentCompleted)
            } else if self.isReady {
                // New photos taken while connected.
                self.scheduleRefresh()
            }
        }
    }

    nonisolated func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {
        Task { @MainActor in if self.isReady { self.scheduleRefresh() } }
    }

    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: Error?) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: Error?) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
    nonisolated func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}

    nonisolated func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {
        Task { @MainActor in
            self.canDelete = camera.capabilities.contains(ICDeviceCapability.cameraDeviceCanDeleteOneFile.rawValue)
        }
    }

    nonisolated func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        Task { @MainActor in self.refreshFiles() }
    }

    nonisolated func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {
        Task { @MainActor in
            if let camera = device as? ICCameraDevice {
                self.status = .loadingCatalog(camera.name ?? "iPhone", camera.contentCatalogPercentCompleted)
            }
        }
    }

    nonisolated func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {
        Task { @MainActor in self.status = .locked(device.name ?? "iPhone") }
    }
}
