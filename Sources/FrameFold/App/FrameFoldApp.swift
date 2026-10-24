import AppKit
import SwiftUI

@main
struct FrameFoldApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = AppState()

    var body: some Scene {
        Window("FrameFold", id: "main") {
            ContentView()
                .environmentObject(state)
                .frame(minWidth: 820, minHeight: 520)
                .onAppear {
                    appDelegate.state = state
                    state.start()
                    #if DEBUG
                    DebugSnapshot.startIfRequested(state: state)
                    #endif
                }
        }
        .defaultSize(width: 1240, height: 800)
        .windowToolbarStyle(.unified)
        .commands { AppCommands(state: state) }

        Settings {
            SettingsView()
                .environmentObject(state)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var state: AppState?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Running from `swift run` has no bundle; make it a regular app with a Dock icon.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { state?.shutdown() }
    }
}

struct AppCommands: Commands {
    @ObservedObject var state: AppState

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Index iPhone") { state.syncNow() }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            Button("Reindex iPhone from Scratch") { state.reindexIPhone() }
                .keyboardShortcut("i", modifiers: [.command, .shift, .option])
            Button("Import Files…") { state.chooseFilesToImport() }
                .keyboardShortcut("o", modifiers: .command)
            Divider()
            Button("Export Originals…") { state.export(state.selection) }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(state.selection.isEmpty)
            Button("Show in Finder") { state.revealInFinder(state.selection) }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(state.selection.isEmpty)
        }

        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Delete…") { state.requestDelete(state.selection) }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(state.selection.isEmpty)
            Button("Deselect All") { state.selection = [] }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(state.selection.isEmpty)
        }

        CommandMenu("Organise") {
            Button("Categorise Uncategorised") { state.categorize(.uncategorized) }
                .keyboardShortcut("k", modifiers: .command)
            Button("Categorise Selection") { state.categorize(.items(state.selection)) }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .disabled(state.selection.isEmpty)
            Button("Recategorise Everything") { state.categorize(.all) }
            Divider()
            Menu("Move Selection to Category") {
                ForEach(state.library.categories) { category in
                    Button(category.name) { state.move(state.selection, to: category.name) }
                }
            }
            .disabled(state.selection.isEmpty)
            Button("New Category from Selection…") { state.newCategoryFor = Array(state.selection) }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(state.selection.isEmpty)
            Divider()
            Button("Find Duplicates") { state.findDuplicates() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            Button("Select Duplicates") { state.selectDuplicates() }
                .keyboardShortcut("d", modifiers: [.command, .option])
                .disabled(state.analysis.duplicateGroups.isEmpty)
            Divider()
            Button("Local Model…") { state.showModelSheet = true }
        }

        CommandGroup(before: .toolbar) {
            Picker("Time Scale", selection: $state.scale) {
                Text("Years").tag(TimeScale.years).keyboardShortcut("1", modifiers: .command)
                Text("Months").tag(TimeScale.months).keyboardShortcut("2", modifiers: .command)
                Text("All Photos").tag(TimeScale.all).keyboardShortcut("3", modifiers: .command)
            }
            .pickerStyle(.inline)
            Button("Zoom In") { state.zoomIn() }
                .keyboardShortcut("+", modifiers: .command)
            Button("Zoom Out") { state.zoomOut() }
                .keyboardShortcut("-", modifiers: .command)
            Button("Collapse All Sections") { state.collapseAll() }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            Button("Expand All Sections") { state.expandAll() }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            Toggle("Show iCloud Badges", isOn: $state.showCloudBadges)
                .keyboardShortcut("b", modifiers: [.command, .option])
            Divider()
        }

        CommandGroup(after: .help) {
            Button("Keyboard Shortcuts") { state.showShortcuts = true }
                .keyboardShortcut("/", modifiers: .command)
        }
    }
}
