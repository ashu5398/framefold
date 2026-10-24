import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var state: AppState
    @State private var categoryName = ""
    @State private var personName = ""

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 320)
        } detail: {
            LibraryView()
        }
        .sheet(isPresented: Binding(get: { state.pendingDelete != nil }, set: { if !$0 { state.pendingDelete = nil } })) {
            if let ids = state.pendingDelete {
                DeleteSheet(ids: ids)
            }
        }
        .sheet(isPresented: $state.showModelSheet) {
            ModelSheet()
        }
        .sheet(isPresented: $state.showShortcuts) {
            ShortcutsView()
        }
        .alert("New Category", isPresented: Binding(get: { state.newCategoryFor != nil }, set: { if !$0 { state.newCategoryFor = nil } })) {
            TextField("Name", text: $categoryName)
            Button("Cancel", role: .cancel) { categoryName = "" }
            Button("Create") {
                let name = categoryName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty {
                    state.library.addCategory(name)
                    if let ids = state.newCategoryFor, !ids.isEmpty { state.move(ids, to: name) }
                }
                categoryName = ""
            }
        } message: {
            if let ids = state.newCategoryFor, !ids.isEmpty {
                Text("\(ids.count) selected item\(ids.count == 1 ? "" : "s") will move into it.")
            }
        }
        .alert("Rename Person", isPresented: Binding(get: { state.renamingPerson != nil }, set: { if !$0 { state.renamingPerson = nil } })) {
            TextField("Name", text: $personName)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                if let person = state.renamingPerson, !personName.trimmingCharacters(in: .whitespaces).isEmpty {
                    state.library.updatePerson(person.id) {
                        $0.name = personName.trimmingCharacters(in: .whitespaces)
                        $0.isNamed = true
                    }
                }
            }
        }
        .onChange(of: state.renamingPerson) { _, person in
            personName = person?.isNamed == true ? person!.name : ""
        }
    }
}
