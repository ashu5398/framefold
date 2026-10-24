import AppKit

/// Context menu for grid items, built in AppKit because the grid is an `NSCollectionView`.
@MainActor
enum GridMenu {
    static func make(for ids: Set<String>, state: AppState) -> NSMenu {
        let menu = NSMenu()
        let plural = ids.count > 1 ? " \(ids.count) Items" : ""

        if ids.count == 1, let id = ids.first {
            menu.addItem(ClosureMenuItem("Open", key: " ") { state.open(id) })
            menu.addItem(.separator())
        }

        let move = NSMenuItem(title: "Move to Category", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for category in state.library.categories {
            let item = ClosureMenuItem(category.name) { state.move(ids, to: category.name) }
            item.image = NSImage(systemSymbolName: category.symbol, accessibilityDescription: nil)
            sub.addItem(item)
        }
        sub.addItem(.separator())
        sub.addItem(ClosureMenuItem("New Category…") { state.newCategoryFor = Array(ids) })
        move.submenu = sub
        menu.addItem(move)
        if ids.contains(where: { state.library.item($0)?.category != nil }) {
            menu.addItem(ClosureMenuItem("Remove Category") { state.move(ids, to: nil) })
        }
        menu.addItem(ClosureMenuItem("Categorise with \(LocalModel.displayName)") { state.categorize(.items(ids)) })
        if case .person(let personID) = state.sidebar, let person = state.library.person(personID) {
            menu.addItem(ClosureMenuItem("Not \(person.name)") { state.removeFromPerson(ids, person: personID) })
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Export Originals…") { state.export(ids) })
        menu.addItem(ClosureMenuItem("Share…") { state.share(ids) })
        menu.addItem(ClosureMenuItem("Show in Finder") { state.revealInFinder(ids) })
        if ids.contains(where: { state.library.item($0)?.pendingDeviceDelete == true }) {
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem("Don't Delete from iPhone") { state.cancelPendingDelete(ids) })
        }
        menu.addItem(.separator())
        let delete = ClosureMenuItem("Delete\(plural)…") { state.requestDelete(ids) }
        delete.keyEquivalent = "\u{8}"
        delete.keyEquivalentModifierMask = .command
        menu.addItem(delete)
        return menu
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, key: String = "", handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: key)
        target = self
        if !key.isEmpty { keyEquivalentModifierMask = [] }
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}
