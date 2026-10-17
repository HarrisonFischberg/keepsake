import SwiftUI
import KeepsakeKit
import KeepsakeUI

/// Collections are for shopping: products sorted into collections, with Purchased.
struct CollectionsScreen: View {
    let zoom: Namespace.ID
    @Environment(LibraryModel.self) private var model
    @Environment(\.ks) private var t
    @State private var collections: [SaveCollection] = []
    @State private var naming = false
    @State private var newName = ""

    var body: some View {
        ZStack {
            TableBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ScreenHeader(title: "Collections", subtitle: "For things to buy")
                    CollectionTiles(collections: collections) { naming = true }
                }
                .padding(.horizontal, 18).padding(.bottom, 40)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .primaryAction) { Button("New collection", systemImage: "plus") { naming = true } } }
        .alert("New collection", isPresented: $naming) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) { newName = "" }
            Button("Create") { Task { _ = try? await model.library?.createCollection(named: newName); newName = ""; await load() } }
        }
        .task(id: model.saves.count) { await load() }
    }

    private func load() async { collections = (try? model.library?.collections()) ?? [] }
}

/// One collection: what's still to buy, then Purchased.
struct CollectionScreen: View {
    let id: String
    let name: String
    let zoom: Namespace.ID
    @Environment(LibraryModel.self) private var model
    @Environment(\.ks) private var t
    @Environment(\.dismiss) private var dismiss
    @State private var editing = false
    private var saves: [Save] { model.saves.filter { $0.collectionId == id } }

    var body: some View {
        ZStack {
            TableBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ScreenHeader(title: name, subtitle: saves.count == 1 ? "1 save" : "\(saves.count) saves")
                    if saves.isEmpty { EmptyNote(symbol: "bag", text: "Nothing here yet. Move a save here from Review or its own screen.") }
                    SaveGrid(saves: saves.filter { $0.purchased != true }, zoom: zoom)
                    let bought = saves.filter { $0.purchased == true }
                    if !bought.isEmpty {
                        Text("Purchased").font(KSFont.name(.title2)).foregroundStyle(t.ink).accessibilityAddTraits(.isHeader)
                        SaveGrid(saves: bought, zoom: zoom)
                    }
                }
                .padding(.horizontal, 18).padding(.bottom, 40)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .primaryAction) { Button("Edit") { editing = true } } }
        .sheet(isPresented: $editing) {
            if let c = try? model.library?.collections().first(where: { $0.id == id }) {
                CollectionEditor(collection: c) { deleted in if deleted { dismiss() } }
            }
        }
    }
}

/// A collection's name, the words that file saves into it, and whether it's pinned. Deleting it
/// sends its saves back to Review (nothing is lost).
struct CollectionEditor: View {
    let collection: SaveCollection
    let done: (Bool) -> Void
    @Environment(LibraryModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var keywords = ""
    @State private var pinned = false
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") { TextField("Name", text: $name) }
                Section {
                    TextField("e.g. dutch oven, skillet, knife", text: $keywords, axis: .vertical)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: { Text("Keywords") } footer: { Text("Saves with these words in them are filed here. Separate them with commas.") }
                Section { Toggle("Pinned", isOn: $pinned) }
                Section {
                    Button("Delete collection", role: .destructive) { confirmDelete = true }
                } footer: { Text("Its saves go back to Review.") }
            }
            .navigationTitle("Edit collection").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            let words = keywords.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                            try? await model.library?.updateCollection(collection.id, ["name": name, "keywords": words, "pinned": pinned])
                            model.refresh()
                            Haptic.settled()
                            dismiss()
                            done(false)
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .confirmationDialog("Delete “\(collection.name)”?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete collection", role: .destructive) {
                    Task {
                        try? await model.library?.deleteCollection(collection.id)
                        model.refresh()
                        Haptic.trashed()
                        dismiss()
                        done(true)
                    }
                }
            } message: { Text("Its saves go back to Review.") }
            .onAppear {
                name = collection.name
                keywords = (collection.keywords ?? []).joined(separator: ", ")
                pinned = collection.pinned ?? false
            }
        }
    }
}
