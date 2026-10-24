import AppKit
import SwiftUI

/// The photo grid. AppKit's collection view gives native selection (⌘/⇧-click, rubber band,
/// ⌘A), fast scrolling over tens of thousands of items, pinned section headers and drag out.
struct PhotoGridView: NSViewRepresentable {
    var sections: [GridSection]
    /// Changes whenever `sections` does; cheaper to compare than the sections themselves.
    var sectionsToken: Int
    var revision: Int
    var itemSize: Double
    var scale: TimeScale
    @Binding var selection: Set<String>
    var showCloudBadges: Bool
    var bestIDs: Set<String>
    var copyMode: Bool
    @Binding var scrollTarget: String?
    var lookup: (String) -> PhotoItem?
    var thumbnailURL: (String) -> URL
    var originalURL: (String) -> URL?
    var onOpen: (String) -> Void
    var onDelete: (Set<String>) -> Void
    var onMagnify: (Double) -> Void
    var onVisibleChange: ([String]) -> Void = { _ in }
    /// Sections whose photos are folded away; their headers stay.
    var collapsed: Set<String> = []
    /// Section id, and whether to apply to every section (⌥-click).
    var onToggleSection: (String, Bool) -> Void = { _, _ in }
    var menu: (Set<String>) -> NSMenu

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let layout = GridLayout()
        let collection = GridCollectionView()
        collection.collectionViewLayout = layout
        collection.isSelectable = true
        collection.allowsMultipleSelection = true
        collection.allowsEmptySelection = true
        collection.backgroundColors = [.clear]
        collection.register(PhotoCell.self, forItemWithIdentifier: PhotoCell.identifier)
        collection.register(SectionHeader.self, forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
                            withIdentifier: SectionHeader.identifier)
        collection.setDraggingSourceOperationMask(.copy, forLocal: false)
        collection.setDraggingSourceOperationMask([.copy, .generic], forLocal: true)
        collection.delegate = context.coordinator
        collection.gridDelegate = context.coordinator
        context.coordinator.attach(collection)

        let scroll = NSScrollView()
        scroll.documentView = collection
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = true
        scroll.contentView.postsBoundsChangedNotifications = true
        context.coordinator.observeScrolling(scroll.contentView)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(with: self)
    }

    // MARK: Coordinator

    @MainActor
    final class Coordinator: NSObject, NSCollectionViewDelegateFlowLayout, GridCollectionViewDelegate {
        var parent: PhotoGridView
        private weak var collection: GridCollectionView?
        private var dataSource: NSCollectionViewDiffableDataSource<String, String>?
        private var appliedSections: [GridSection] = []
        private var appliedToken = -1
        private var appliedCollapsed: Set<String> = []
        private var appliedRevision = -1
        private var appliedScale: TimeScale?
        private var isSyncingSelection = false
        private var observer: NSObjectProtocol?

        init(_ parent: PhotoGridView) {
            self.parent = parent
        }

        func attach(_ collection: GridCollectionView) {
            self.collection = collection
            let source = NSCollectionViewDiffableDataSource<String, String>(collectionView: collection) { [weak self] view, indexPath, id in
                let cell = view.makeItem(withIdentifier: PhotoCell.identifier, for: indexPath) as! PhotoCell
                self?.configure(cell, id: id)
                return cell
            }
            source.supplementaryViewProvider = { [weak self] view, kind, indexPath in
                let header = view.makeSupplementaryView(ofKind: kind, withIdentifier: SectionHeader.identifier, for: indexPath) as! SectionHeader
                if let self, indexPath.section < self.appliedSections.count {
                    let section = self.appliedSections[indexPath.section]
                    header.configure(title: section.title, subtitle: section.subtitle, scale: self.parent.scale,
                                     collapsed: self.parent.collapsed.contains(section.id))
                    header.onToggle = { [weak self] all in self?.parent.onToggleSection(section.id, all) }
                }
                return header
            }
            dataSource = source
            observer = NotificationCenter.default.addObserver(forName: .thumbnailUpdated, object: nil, queue: .main) { [weak self] note in
                guard let id = note.userInfo?["id"] as? String else { return }
                MainActor.assumeIsolated { self?.reloadThumbnail(id) }
            }
        }

        private var scrollObserver: NSObjectProtocol?
        private var visibleWork: DispatchWorkItem?

        func observeScrolling(_ clip: NSClipView) {
            scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleVisibleReport() }
            }
        }

        /// Reports what's on screen shortly after scrolling settles.
        private func scheduleVisibleReport() {
            visibleWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let collection = self.collection, let dataSource = self.dataSource else { return }
                    let ids = collection.indexPathsForVisibleItems().sorted().compactMap { dataSource.itemIdentifier(for: $0) }
                    self.parent.onVisibleChange(ids)
                }
            }
            visibleWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        }

        func update(with parent: PhotoGridView) {
            self.parent = parent
            guard let collection, let dataSource, let layout = collection.collectionViewLayout as? GridLayout else { return }

            if layout.targetSize != parent.itemSize || appliedScale != parent.scale {
                layout.targetSize = parent.itemSize
                layout.headerHeight = parent.scale == .years ? 52 : 44
                layout.invalidateLayout()
            }

            if parent.sectionsToken != appliedToken || appliedScale != parent.scale || parent.collapsed != appliedCollapsed {
                appliedToken = parent.sectionsToken
                appliedCollapsed = parent.collapsed
                appliedSections = parent.sections
                appliedScale = parent.scale
                var snapshot = NSDiffableDataSourceSnapshot<String, String>()
                for section in parent.sections {
                    snapshot.appendSections([section.id])
                    if !parent.collapsed.contains(section.id) {
                        snapshot.appendItems(section.itemIDs, toSection: section.id)
                    }
                }
                dataSource.apply(snapshot, animatingDifferences: false)
                // A section that only folded keeps its header view, so update visible chevrons.
                refreshHeaders()
                appliedRevision = parent.revision
                scheduleVisibleReport()
            } else if parent.revision != appliedRevision {
                appliedRevision = parent.revision
                refreshVisibleCells()
            }

            syncSelectionToView()

            if let target = parent.scrollTarget {
                DispatchQueue.main.async {
                    self.scroll(toSection: target)
                    parent.scrollTarget = nil
                }
            }
        }

        private func configure(_ cell: PhotoCell, id: String) {
            guard let item = parent.lookup(id) else { return }
            cell.configure(item: item, showCloud: parent.showCloudBadges, isBest: parent.bestIDs.contains(id),
                           compact: parent.scale == .years, copyMode: parent.copyMode, thumbnailURL: parent.thumbnailURL(id))
        }

        private func refreshVisibleCells() {
            guard let collection, let dataSource else { return }
            for indexPath in collection.indexPathsForVisibleItems() {
                guard let id = dataSource.itemIdentifier(for: indexPath),
                      let cell = collection.item(at: indexPath) as? PhotoCell else { continue }
                configure(cell, id: id)
            }
            for case let header as SectionHeader in collection.visibleSupplementaryViews(ofKind: NSCollectionView.elementKindSectionHeader) {
                header.needsDisplay = true
            }
        }

        private func refreshHeaders() {
            guard let collection else { return }
            for indexPath in collection.indexPathsForVisibleSupplementaryElements(ofKind: NSCollectionView.elementKindSectionHeader) {
                guard indexPath.section < appliedSections.count,
                      let header = collection.supplementaryView(forElementKind: NSCollectionView.elementKindSectionHeader, at: indexPath) as? SectionHeader
                else { continue }
                let section = appliedSections[indexPath.section]
                header.configure(title: section.title, subtitle: section.subtitle, scale: parent.scale,
                                 collapsed: parent.collapsed.contains(section.id))
                header.onToggle = { [weak self] all in self?.parent.onToggleSection(section.id, all) }
            }
        }

        private func reloadThumbnail(_ id: String) {
            guard let collection, let dataSource, let indexPath = dataSource.indexPath(for: id),
                  let cell = collection.item(at: indexPath) as? PhotoCell else { return }
            configure(cell, id: id)
        }

        private func scroll(toSection id: String) {
            guard let collection, let index = appliedSections.firstIndex(where: { $0.id == id }) else { return }
            collection.layoutSubtreeIfNeeded()
            let indexPath = IndexPath(item: 0, section: index)
            if let attrs = collection.layoutAttributesForSupplementaryElement(ofKind: NSCollectionView.elementKindSectionHeader, at: indexPath) {
                collection.scroll(NSPoint(x: 0, y: attrs.frame.minY))
            }
        }

        // MARK: Selection

        private func ids(for indexPaths: Set<IndexPath>) -> Set<String> {
            Set(indexPaths.compactMap { dataSource?.itemIdentifier(for: $0) })
        }

        private func syncSelectionToView() {
            guard let collection, let dataSource else { return }
            let current = ids(for: collection.selectionIndexPaths)
            guard current != parent.selection else { return }
            isSyncingSelection = true
            collection.selectionIndexPaths = Set(parent.selection.compactMap { dataSource.indexPath(for: $0) })
            isSyncingSelection = false
        }

        private func pushSelection() {
            guard !isSyncingSelection, let collection else { return }
            let ids = ids(for: collection.selectionIndexPaths)
            if ids != parent.selection { parent.selection = ids }
        }

        func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) { pushSelection() }
        func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) { pushSelection() }

        /// Folded sections sit flush, as a compact list of headers.
        func collectionView(_ collectionView: NSCollectionView, layout collectionViewLayout: NSCollectionViewLayout,
                            insetForSectionAt section: Int) -> NSEdgeInsets {
            let folded = section < appliedSections.count && appliedCollapsed.contains(appliedSections[section].id)
            let inset = (collectionViewLayout as? GridLayout)?.inset ?? 2
            return NSEdgeInsets(top: 0, left: inset, bottom: folded ? 1 : 12, right: inset)
        }

        // MARK: Drag out

        func collectionView(_ collectionView: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>, with event: NSEvent) -> Bool {
            true
        }

        /// Every drag carries the item id, so it can be dropped on a sidebar category. Items with
        /// an original on this Mac also carry the file, for Finder and other apps.
        func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
            guard let id = dataSource?.itemIdentifier(for: indexPath) else { return nil }
            let item = NSPasteboardItem()
            item.setString(GridDrag.prefix + id, forType: .string)
            if let url = parent.originalURL(id) {
                item.setString(url.absoluteString, forType: .fileURL)
            }
            return item
        }

        // MARK: GridCollectionViewDelegate

        func grid(_ grid: GridCollectionView, didDoubleClick indexPath: IndexPath) {
            if let id = dataSource?.itemIdentifier(for: indexPath) { parent.onOpen(id) }
        }

        func gridOpenSelection(_ grid: GridCollectionView) {
            if let id = parent.selection.first ?? nil { parent.onOpen(id) }
        }

        func gridDeleteSelection(_ grid: GridCollectionView) {
            if !parent.selection.isEmpty { parent.onDelete(parent.selection) }
        }

        func grid(_ grid: GridCollectionView, magnify factor: Double) {
            parent.onMagnify(factor)
        }

        func grid(_ grid: GridCollectionView, menuFor indexPath: IndexPath) -> NSMenu? {
            guard let id = dataSource?.itemIdentifier(for: indexPath) else { return nil }
            if !parent.selection.contains(id) {
                grid.selectionIndexPaths = [indexPath]
                pushSelection()
            }
            return parent.menu(parent.selection.isEmpty ? [id] : parent.selection)
        }

        func gridDidChangeSelection(_ grid: GridCollectionView) {
            pushSelection()
        }

        func gridToggle(_ grid: GridCollectionView, indexPath: IndexPath) {
            if grid.selectionIndexPaths.contains(indexPath) {
                grid.deselectItems(at: [indexPath])
            } else {
                grid.selectItems(at: [indexPath], scrollPosition: [])
            }
            pushSelection()
        }
    }
}

enum GridDrag {
    static let prefix = "framefold-item:"

    static func ids(from strings: [String]) -> [String] {
        strings.flatMap { $0.split(separator: "\n") }
            .filter { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)) }
    }
}

// MARK: - Collection view

@MainActor
protocol GridCollectionViewDelegate: AnyObject {
    func grid(_ grid: GridCollectionView, didDoubleClick indexPath: IndexPath)
    func gridOpenSelection(_ grid: GridCollectionView)
    func gridDeleteSelection(_ grid: GridCollectionView)
    func grid(_ grid: GridCollectionView, magnify factor: Double)
    func grid(_ grid: GridCollectionView, menuFor indexPath: IndexPath) -> NSMenu?
    func gridToggle(_ grid: GridCollectionView, indexPath: IndexPath)
    func gridDidChangeSelection(_ grid: GridCollectionView)
}

final class GridCollectionView: NSCollectionView {
    weak var gridDelegate: GridCollectionViewDelegate?
    private var magnifyAccumulator: Double = 0
    /// Where a ⇧-click range starts: the last item clicked without ⇧.
    private var selectionAnchor: IndexPath?

    private func indexPaths(from a: IndexPath, to b: IndexPath) -> Set<IndexPath> {
        let (start, end) = a < b ? (a, b) : (b, a)
        var result = Set<IndexPath>()
        for section in start.section...end.section {
            let first = section == start.section ? start.item : 0
            let last = section == end.section ? end.item : numberOfItems(inSection: section) - 1
            guard first <= last else { continue }
            for item in first...last { result.insert(IndexPath(item: item, section: section)) }
        }
        return result
    }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        let indexPath = indexPathForItem(at: point)
        // ⇧-click selects every item from the last clicked one to this one, across sections.
        if event.modifierFlags.contains(.shift), let indexPath, let anchor = selectionAnchor {
            selectItems(at: indexPaths(from: anchor, to: indexPath), scrollPosition: [])
            gridDelegate?.gridDidChangeSelection(self)
            return
        }
        // ⌃-click toggles selection, like ⌘-click. Right-click (or two-finger click) opens the menu.
        if event.modifierFlags.contains(.control), let indexPath {
            gridDelegate?.gridToggle(self, indexPath: indexPath)
            selectionAnchor = indexPath
            return
        }
        super.mouseDown(with: event)
        selectionAnchor = indexPath
        if event.clickCount == 2, let indexPath {
            gridDelegate?.grid(self, didDoubleClick: indexPath)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        if event.type == .leftMouseDown { return nil }
        let point = convert(event.locationInWindow, from: nil)
        guard let indexPath = indexPathForItem(at: point) else { return nil }
        return gridDelegate?.grid(self, menuFor: indexPath)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 49, 36, 76: // space, return, enter
            gridDelegate?.gridOpenSelection(self)
        case 51, 117: // delete, forward delete
            gridDelegate?.gridDeleteSelection(self)
        case 53: // escape
            deselectAll(nil)
            delegate?.collectionView?(self, didDeselectItemsAt: [])
        default:
            super.keyDown(with: event)
        }
    }

    override func magnify(with event: NSEvent) {
        magnifyAccumulator += event.magnification
        if abs(magnifyAccumulator) > 0.08 || event.phase == .ended {
            gridDelegate?.grid(self, magnify: 1 + magnifyAccumulator)
            magnifyAccumulator = 0
        }
    }
}

// MARK: - Layout

/// Flow layout that fills the width with equal square tiles close to `targetSize`.
final class GridLayout: NSCollectionViewFlowLayout {
    var targetSize: Double = 150
    var headerHeight: CGFloat = 44
    let spacing: CGFloat = 2
    let inset: CGFloat = 2

    override init() {
        super.init()
        minimumInteritemSpacing = spacing
        minimumLineSpacing = spacing
        sectionHeadersPinToVisibleBounds = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func prepare() {
        if let width = collectionView?.enclosingScrollView?.contentView.bounds.width ?? collectionView?.bounds.width, width > 0 {
            let available = width - inset * 2
            let columns = max(1, Int((available + spacing) / (CGFloat(targetSize) + spacing)))
            let side = floor((available - spacing * CGFloat(columns - 1)) / CGFloat(columns))
            itemSize = NSSize(width: side, height: side)
            sectionInset = NSEdgeInsets(top: 0, left: inset, bottom: 12, right: inset)
            headerReferenceSize = NSSize(width: width, height: headerHeight)
        }
        super.prepare()
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        true
    }
}
