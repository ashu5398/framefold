import Foundation

/// Where an item lives relative to iCloud Photos.
enum CloudState: String, Codable {
    /// Photos access not granted, or matching has not run yet.
    case unknown
    /// Found in the Mac's Photos library, which is kept in sync with iCloud Photos.
    case inCloud
    /// Not found in the iCloud-synced library: only on the iPhone and in FrameFold.
    case notInCloud
}

enum MediaKind: String, Codable {
    case photo
    case video
}

enum CategorySource: String, Codable {
    /// Picked by the local decision model.
    case model
    /// Taken from an album in the Photos app.
    case photos
    /// Set by the user.
    case manual
}

/// One photo or video. For iPhone items this is a pointer: the original stays on the phone, and
/// FrameFold keeps the id, a thumbnail and everything it learns (category, people, labels).
struct PhotoItem: Codable, Identifiable, Hashable {
    /// Stable across reconnects: derived from the device file's name, size and capture time.
    var id: String
    var fileName: String
    var captureDate: Date
    var fileSize: Int64
    var pixelWidth: Int
    var pixelHeight: Int
    var kind: MediaKind
    var duration: Double?

    /// A full copy kept on this Mac, relative to the library's Originals folder. `nil` in
    /// browse-only mode, where the original is read from the iPhone when needed.
    var relativePath: String?
    /// The phone this item lives on (`ICDevice.persistentIDString`). `nil` for imported files.
    var deviceID: String?
    var deviceName: String?
    /// Present on that phone right now (it is connected and listed the file).
    var onDevice = false
    var hasThumbnail = false
    var syncedAt: Date?
    /// Delete from the iPhone the next time it connects.
    var pendingDeviceDelete = false

    var cloud: CloudState = .unknown
    var photosAssetID: String?
    var albums: [String] = []

    var category: String?
    var categorySource: CategorySource?
    var categoryConfidence: Double?

    var labels: [String] = []
    var recognizedText: String?
    var faceCount = 0
    /// Face pipeline that produced this item's faces (`FaceRecognizer.pipelineVersion`).
    var faceVersion = 0
    var personIDs: [String] = []
    var contentHash: String?
    var analyzed = false
    /// A file the Photos app shows as part of another item: the original behind an edited photo,
    /// a non-cover burst frame, or the video half of a Live Photo. Hidden from the grid; it goes
    /// wherever its main item goes.
    var isCompanion = false
    /// On a main item: the files folded behind it (see `isCompanion`).
    var companionIDs: [String] = []
    /// On a main item that stands for a burst: how many frames the burst has.
    var burstCount: Int?
    /// Edited on the phone, but the phone only exposes the original over USB; its edited version
    /// lives in Photos' private storage. Deleting over USB would remove only the original, so
    /// such items must be deleted in the Photos app.
    var editedOnPhoneOnly = false

    /// A full copy lives in the library on this Mac.
    var isCopied: Bool { relativePath != nil }
    var isFromDevice: Bool { deviceID != nil }
    var isVideo: Bool { kind == .video }
    var pixelCount: Int { pixelWidth * pixelHeight }

    var fileStem: String {
        (fileName as NSString).deletingPathExtension.uppercased()
    }

    /// Key for byte-identical files: the hash when known, otherwise size and dimensions, which
    /// is what an identical file on the phone shares without reading it.
    var exactKey: String {
        contentHash ?? "\(fileSize)-\(pixelWidth)x\(pixelHeight)-\(kind.rawValue)"
    }

    init(id: String, fileName: String, captureDate: Date, fileSize: Int64, pixelWidth: Int, pixelHeight: Int,
         kind: MediaKind, duration: Double? = nil) {
        self.id = id
        self.fileName = fileName
        self.captureDate = captureDate
        self.fileSize = fileSize
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.kind = kind
        self.duration = duration
    }

    // Tolerates fields missing from older library files.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        fileName = try c.decode(String.self, forKey: .fileName)
        captureDate = try c.decode(Date.self, forKey: .captureDate)
        fileSize = try c.decodeIfPresent(Int64.self, forKey: .fileSize) ?? 0
        pixelWidth = try c.decodeIfPresent(Int.self, forKey: .pixelWidth) ?? 0
        pixelHeight = try c.decodeIfPresent(Int.self, forKey: .pixelHeight) ?? 0
        kind = try c.decodeIfPresent(MediaKind.self, forKey: .kind) ?? .photo
        duration = try c.decodeIfPresent(Double.self, forKey: .duration)
        relativePath = try c.decodeIfPresent(String.self, forKey: .relativePath)
        deviceID = try c.decodeIfPresent(String.self, forKey: .deviceID)
        deviceName = try c.decodeIfPresent(String.self, forKey: .deviceName)
        onDevice = try c.decodeIfPresent(Bool.self, forKey: .onDevice) ?? false
        hasThumbnail = try c.decodeIfPresent(Bool.self, forKey: .hasThumbnail) ?? false
        syncedAt = try c.decodeIfPresent(Date.self, forKey: .syncedAt)
        pendingDeviceDelete = try c.decodeIfPresent(Bool.self, forKey: .pendingDeviceDelete) ?? false
        cloud = try c.decodeIfPresent(CloudState.self, forKey: .cloud) ?? .unknown
        photosAssetID = try c.decodeIfPresent(String.self, forKey: .photosAssetID)
        albums = try c.decodeIfPresent([String].self, forKey: .albums) ?? []
        category = try c.decodeIfPresent(String.self, forKey: .category)
        categorySource = try c.decodeIfPresent(CategorySource.self, forKey: .categorySource)
        categoryConfidence = try c.decodeIfPresent(Double.self, forKey: .categoryConfidence)
        labels = try c.decodeIfPresent([String].self, forKey: .labels) ?? []
        recognizedText = try c.decodeIfPresent(String.self, forKey: .recognizedText)
        faceCount = try c.decodeIfPresent(Int.self, forKey: .faceCount) ?? 0
        faceVersion = try c.decodeIfPresent(Int.self, forKey: .faceVersion) ?? 0
        personIDs = try c.decodeIfPresent([String].self, forKey: .personIDs) ?? []
        contentHash = try c.decodeIfPresent(String.self, forKey: .contentHash)
        analyzed = try c.decodeIfPresent(Bool.self, forKey: .analyzed) ?? false
        isCompanion = try c.decodeIfPresent(Bool.self, forKey: .isCompanion) ?? false
        companionIDs = try c.decodeIfPresent([String].self, forKey: .companionIDs) ?? []
        burstCount = try c.decodeIfPresent(Int.self, forKey: .burstCount)
        editedOnPhoneOnly = try c.decodeIfPresent(Bool.self, forKey: .editedOnPhoneOnly) ?? false
    }
}

struct Person: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    /// A face crop used as the avatar, relative to the library's Faces folder.
    var avatarPath: String?
    var isHidden: Bool = false
    /// Faces assigned to this person, as `<photo id>_<face index>`.
    var faceKeys: [String] = []
    /// The user gave this person a name.
    var isNamed: Bool = false
    /// Photos the user said this person is not in; regrouping keeps them out.
    var rejectedPhotoIDs: [String] = []
    /// The user merged other people into this one; regrouping keeps them together.
    var isUserMerged: Bool = false

    init(id: String, name: String, avatarPath: String? = nil, faceKeys: [String] = []) {
        self.id = id
        self.name = name
        self.avatarPath = avatarPath
        self.faceKeys = faceKeys
    }

    // Tolerates fields missing from older library files.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        avatarPath = try c.decodeIfPresent(String.self, forKey: .avatarPath)
        isHidden = try c.decodeIfPresent(Bool.self, forKey: .isHidden) ?? false
        faceKeys = try c.decodeIfPresent([String].self, forKey: .faceKeys) ?? []
        isNamed = try c.decodeIfPresent(Bool.self, forKey: .isNamed) ?? false
        rejectedPhotoIDs = try c.decodeIfPresent([String].self, forKey: .rejectedPhotoIDs) ?? []
        isUserMerged = try c.decodeIfPresent(Bool.self, forKey: .isUserMerged) ?? false
    }
}

struct PhotoCategory: Codable, Identifiable, Hashable {
    var id: String { name }
    var name: String
    var detail: String
    var symbol: String

    init(name: String, detail: String, symbol: String) {
        self.name = name
        self.detail = detail
        self.symbol = symbol
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        detail = try c.decodeIfPresent(String.self, forKey: .detail) ?? name
        symbol = try c.decodeIfPresent(String.self, forKey: .symbol) ?? "folder"
    }

    static let defaults: [PhotoCategory] = [
        .init(name: "People", detail: "Portraits, groups of friends or family, people as the main subject", symbol: "person.2"),
        .init(name: "Selfies", detail: "A person photographing themselves, front camera, arm-length portrait", symbol: "person.crop.square"),
        .init(name: "Pets & Animals", detail: "Dogs, cats, birds, wildlife or any animal as the subject", symbol: "pawprint"),
        .init(name: "Food & Drink", detail: "Meals, dishes, drinks, restaurants, cooking, groceries", symbol: "fork.knife"),
        .init(name: "Nature", detail: "Landscapes, mountains, beaches, sky, sunsets, plants, flowers, forests", symbol: "leaf"),
        .init(name: "Travel", detail: "Landmarks, monuments, airports, hotels, sightseeing, tourist places", symbol: "airplane"),
        .init(name: "City & Architecture", detail: "Buildings, streets, interiors of public places, skylines", symbol: "building.2"),
        .init(name: "Documents", detail: "Paper documents, receipts, bills, forms, notes, whiteboards, books, IDs", symbol: "doc.text"),
        .init(name: "Screenshots", detail: "Screen captures of phone apps, chats, websites or user interfaces", symbol: "camera.viewfinder"),
        .init(name: "Events", detail: "Parties, weddings, birthdays, concerts, festivals, celebrations", symbol: "party.popper"),
        .init(name: "Sports & Fitness", detail: "Sports, games, gym, running, cycling, outdoor activities", symbol: "figure.run"),
        .init(name: "Vehicles", detail: "Cars, bikes, motorcycles, boats, trains, planes as the subject", symbol: "car"),
        .init(name: "Home", detail: "Rooms, furniture, home decor, household objects", symbol: "house"),
        .init(name: "Shopping & Products", detail: "Products, packaging, clothes, gadgets, store shelves", symbol: "bag"),
        .init(name: "Art & Design", detail: "Paintings, drawings, illustrations, graphic designs, sculptures", symbol: "paintpalette"),
        .init(name: "Other", detail: "Anything that fits none of the other categories", symbol: "square.grid.2x2"),
    ]

    static func symbol(for name: String, in list: [PhotoCategory]) -> String {
        list.first { $0.name == name }?.symbol ?? "folder"
    }
}

/// How FrameFold stores an iPhone's photos.
enum StorageMode: String, Codable, CaseIterable, Identifiable {
    /// Keep thumbnails and organisation data only; read originals from the iPhone when needed.
    case browseOnly
    /// Also keep a full copy of every original on this Mac.
    case copyToMac
    var id: String { rawValue }

    static var current: StorageMode {
        get { UserDefaults.standard.string(forKey: "storageMode").flatMap(StorageMode.init) ?? .browseOnly }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "storageMode") }
    }
}

/// Everything persisted in `library.json`.
struct LibraryIndex: Codable {
    var version: Int = 2
    var items: [PhotoItem] = []
    var people: [Person] = []
    var categories: [PhotoCategory] = PhotoCategory.defaults
    /// Items removed from FrameFold only; indexing must not bring them back.
    var excludedIDs: Set<String> = []
    /// Items deleted from the iPhone or iCloud, by when. The phone can keep listing a file for a
    /// while (iCloud deletes reach it on its next sync), and indexing must not re-add it meanwhile.
    var deletedAt: [String: Date] = [:]

    init(items: [PhotoItem], people: [Person], categories: [PhotoCategory], excludedIDs: Set<String>, deletedAt: [String: Date]) {
        self.items = items
        self.people = people
        self.categories = categories
        self.excludedIDs = excludedIDs
        self.deletedAt = deletedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        items = try c.decodeIfPresent([PhotoItem].self, forKey: .items) ?? []
        people = try c.decodeIfPresent([Person].self, forKey: .people) ?? []
        categories = try c.decodeIfPresent([PhotoCategory].self, forKey: .categories) ?? PhotoCategory.defaults
        excludedIDs = try c.decodeIfPresent(Set<String>.self, forKey: .excludedIDs) ?? []
        deletedAt = try c.decodeIfPresent([String: Date].self, forKey: .deletedAt) ?? [:]
    }
}
