import SwiftUI
import UniformTypeIdentifiers
import KeepsakeKit
import KeepsakeUI

/// Library: Home's shape with everything in it. Your Collections, then your Lifestyle views, each a
/// stack you open to see its saves; chips narrow it to one group, and filtering, searching or
/// selecting lays the saves out as objects. One primary action, finding a save, lives at the bottom
/// under the thumb (the search dock); paste-a-link sits beside it.
struct LibraryScreen: View {
    let zoom: Namespace.ID
    @Environment(LibraryModel.self) private var model
    @Environment(\.ks) private var t
    @Environment(\.accessibilityReduceMotion) private var reduce
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.appearance) private var appearance
    @State private var filter: Filter = .all
    @State private var query = ""
    @State private var results: SearchResult?
    @State private var importing = false
    @State private var status: String?          // "todo", "done", "purchased"
    @State private var source: String?          // a site (host)
    @State private var selecting = false
    @State private var selected: Set<String> = []
    @State private var destinations: [Destination] = []
    @State private var collections: [SaveCollection] = []
    @State private var naming = false
    @State private var newName = ""
    @FocusState private var searching: Bool

    enum Filter: Hashable { case all, collections, lifestyle, review, kind(String), collection(String) }

    /// Stacks (Collections and Lifestyle) rather than saves: nothing is narrowing the saves themselves.
    private var grouped: Bool {
        guard query.trimmingCharacters(in: .whitespaces).isEmpty, status == nil, source == nil, !selecting else { return false }
        return filter == .all || filter == .collections || filter == .lifestyle
    }

    private var shown: [Save] {
        if let results, !query.trimmingCharacters(in: .whitespaces).isEmpty { return results.items }
        var list: [Save]
        switch filter {
        case .all: list = model.saves
        case .collections: list = model.saves.filter { !($0.collectionId ?? "").isEmpty }
        case .lifestyle: list = model.saves.filter(\.hasOwnView)
        case .review: list = model.saves.filter { $0.needsCollection && $0.purchased != true }
        case .kind(let k): list = model.saves.filter { $0.kind == k }
        case .collection(let id): list = model.saves.filter { $0.collectionId == id }
        }
        switch status {
        case "todo": list = list.filter { $0.status != "done" && $0.purchased != true }
        case "done": list = list.filter { $0.status == "done" }
        case "purchased": list = list.filter { $0.purchased == true }
        default: break
        }
        if let source { list = list.filter { $0.host == source } }
        return list
    }

    /// The sites you save from most, for the Source filter.
    private var topSources: [String] {
        var counts: [String: Int] = [:]
        for s in model.saves { if let h = s.host, !h.isEmpty { counts[h, default: 0] += 1 } }
        return counts.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }.prefix(12).map(\.key)
    }

    private let statusNames = ["todo": "To do", "done": "Done", "purchased": "Purchased"]

    /// Kinds the library has, in Chrome's menu order.
    private var kinds: [String] {
        let present = Set(model.saves.map(\.kind))
        return ["place", "recipe", "product", "media", "book", "workout", "video", "article", "link"].filter(present.contains)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            TableBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    if !model.saves.isEmpty && query.isEmpty { filters }
                    content
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 130)
            }
            .scrollDismissesKeyboard(.immediately)
            .safeAreaInset(edge: .top, spacing: 0) { TopScrim() }
            if selecting { selectionBar } else { dock }
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { DispatchQueue.main.async { Perf.done("Library on screen") } }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            if case .success(let url) = result { Task { await model.importFile(url) } }
        }
        .alert("New collection", isPresented: $naming) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) { newName = "" }
            Button("Create") { Task { _ = try? await model.library?.createCollection(named: newName); newName = ""; loadCollections() } }
        }
        .task(id: model.saves.count) { loadCollections() }
        .onChange(of: model.focusSearch, initial: true) { _, want in
            if want { searching = true; model.focusSearch = false }
        }
        .task(id: query) {
            let q = query.trimmingCharacters(in: .whitespaces)
            guard !q.isEmpty, let library = model.library else { results = nil; return }
            try? await Task.sleep(for: .milliseconds(120))
            results = try? await library.search(q)
        }
    }

    private func loadCollections() { collections = (try? model.library?.collections()) ?? [] }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Library").font(KSFont.display()).foregroundStyle(t.ink)
                    .accessibilityAddTraits(.isHeader)
                Text(model.saves.count == 1 ? "1 save, kept on this iPhone" : "\(model.saves.count) saves, kept on this iPhone")
                    .font(KSFont.note).foregroundStyle(t.inkMuted)
            }
            Spacer()
            Menu {
                Button(selecting ? "Done selecting" : "Select", systemImage: "checkmark.circle") {
                    selecting.toggle()
                    selected = []
                }
                Button("Import from Chrome", systemImage: "square.and.arrow.down") { importing = true }
            } label: {
                Image(systemName: "ellipsis").font(.body.weight(.semibold)).foregroundStyle(t.ink)
                    .padding(12).frame(minWidth: 44, minHeight: 44)
                    .background(t.paper, in: Circle())
                    .overlay(Circle().strokeBorder(t.rule, lineWidth: 0.75))
            }
            .accessibilityLabel("More")
        }
        .padding(.top, 8)
    }

    private var filters: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                Chip("All", selected: filter == .all) { set(.all) }
                Chip("Collections", symbol: "bag", tint: KindStyle("product").color, selected: filter == .collections) { set(.collections) }
                Chip("Lifestyle", symbol: "sparkles", tint: KindStyle("recipe").color, selected: filter == .lifestyle) { set(.lifestyle) }
                if model.reviewCount > 0 {
                    Chip("Review \(model.reviewCount)", symbol: "tray", selected: filter == .review) { set(.review) }
                }
                divider
                ForEach(collections) { c in
                    Chip(c.name, symbol: "bag", tint: KindStyle("product").color, selected: filter == .collection(c.id)) { set(.collection(c.id)) }
                        .accessibilityLabel("Collection \(c.name)")
                }
                if !collections.isEmpty && !kinds.isEmpty { divider }
                ForEach(kinds, id: \.self) { k in
                    let s = KindStyle(k)
                    Chip(plural(k), symbol: s.symbol, tint: s.color, selected: filter == .kind(k)) { set(.kind(k)) }
                }
                if let status {
                    Chip("\(statusNames[status] ?? status)  ✕", selected: true) { self.status = nil }
                        .accessibilityLabel("Remove filter \(statusNames[status] ?? status)")
                }
                if let source {
                    Chip("\(source)  ✕", selected: true) { self.source = nil }
                        .accessibilityLabel("Remove filter \(source)")
                }
                Menu {
                    Picker("Status", selection: $status) {
                        Text("Any status").tag(String?.none)
                        ForEach(["todo", "done", "purchased"], id: \.self) { Text(statusNames[$0]!).tag(String?.some($0)) }
                    }
                    Picker("Source", selection: $source) {
                        Text("Any site").tag(String?.none)
                        ForEach(topSources, id: \.self) { Text($0).tag(String?.some($0)) }
                    }
                } label: {
                    Label("Filter", systemImage: "line.3.horizontal.decrease").font(.subheadline.weight(.medium)).foregroundStyle(t.ink)
                        .padding(.horizontal, 14).frame(minHeight: 44)
                        .overlay(Capsule().strokeBorder(t.rule, lineWidth: 0.75))
                }
            }
            .padding(.horizontal, 18)
        }
        .scrollIndicators(.hidden)
        .padding(.horizontal, -18)
    }

    /// A hairline between the chip groups: the two libraries, your collections, then the kinds.
    private var divider: some View {
        Rectangle().fill(t.rule).frame(width: 1, height: 22).padding(.horizontal, 2).accessibilityHidden(true)
    }

    private func set(_ f: Filter) {
        withAnimation(KSMotion.or(KSMotion.settle, reduce: reduce)) { filter = f }
    }

    private func plural(_ k: String) -> String {
        switch k {
        case "media": "Films & shows"; case "link": "Links"
        default: KindStyle(k).label + "s"
        }
    }

    @ViewBuilder private var content: some View {
        if let problem = model.problem {
            EmptyNote(symbol: "exclamationmark.triangle", text: problem)
        } else if !model.loaded {
            ProgressView().frame(maxWidth: .infinity).padding(.top, 80)
        } else if model.saves.isEmpty {
            EmptyNote(symbol: "bookmark", text: "Nothing saved yet. Share a page, a post or a place to Keepsake from any app, or import your Chrome library.") {
                importing = true
            }
        } else if grouped {
            overview
        } else if shown.isEmpty {
            EmptyNote(symbol: "magnifyingglass", text: query.isEmpty ? "Nothing here yet." : "No saves match “\(query)”.")
        } else {
            if let results, results.corrected {
                Text("Showing results for “\(results.query)”").font(KSFont.note).foregroundStyle(t.inkMuted)
            }
            Masonry(shown, columns: typeSize.isAccessibilitySize ? 1 : nil, minColumnWidth: appearance.density == "compact" ? 105 : 170) { save in
                if selecting {
                    let on = selected.contains(save.id)
                    Button {
                        Haptic.checked()
                        if on { selected.remove(save.id) } else { selected.insert(save.id) }
                    } label: {
                        SaveObject(save)
                            .overlay(alignment: .topTrailing) {
                                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                    .font(.title2).foregroundStyle(on ? t.accent : t.inkMuted)
                                    .background(Circle().fill(t.paper)).padding(8)
                            }
                            .opacity(on ? 1 : 0.85)
                    }
                    .buttonStyle(PressStyle())
                    .accessibilityAddTraits(on ? .isSelected : [])
                } else {
                NavigationLink(value: save) {
                    SaveObject(save).matchedTransitionSource(id: save.id, in: zoom)
                }
                .buttonStyle(PressStyle())
                .draggable(save.id) { SaveObject(save).frame(width: 160) }
                // VoiceOver rotor: the card's own actions without opening it.
                .accessibilityAction(named: save.status == "done" ? "Mark not \(KindStyle(save.kind).doneVerb.lowercased())" : "Mark \(KindStyle(save.kind).doneVerb.lowercased())") {
                    Task { await model.setDone(save, save.status != "done") }
                }
                .accessibilityAction(named: "Move to Trash") { Task { await model.trash(save) } }
                .contextMenu {
                    Button("Move to Trash", systemImage: "trash", role: .destructive) { Task { await model.trash(save) } }
                }
                }
            }
        }
    }

    /// Collections first, then Lifestyle: each group a stack with one of its pictures, opening to its saves.
    @ViewBuilder private var overview: some View {
        VStack(alignment: .leading, spacing: 30) {
            if filter == .all, model.reviewCount > 0 { reviewRow }
            if filter != .lifestyle {
                let filed = model.saves.filter { !($0.collectionId ?? "").isEmpty }.count
                GroupSection(title: "Collections", detail: "\(count(collections.count, "collection")) · \(count(filed, "save"))") {
                    CollectionTiles(collections: collections) { naming = true }
                }
            }
            if filter != .collections {
                let lifestyle = model.saves.filter(\.hasOwnView)
                GroupSection(title: "Lifestyle", detail: "\(count(Set(lifestyle.map(\.kind)).count, "view")) · \(count(lifestyle.count, "save"))") {
                    if lifestyle.isEmpty {
                        Text("Recipes, places, workouts, films and books land here.").font(KSFont.note).foregroundStyle(t.inkMuted)
                    } else {
                        LifestyleTiles()
                    }
                }
            }
        }
        .padding(.top, 4)
    }

    /// Saves waiting for a home, as one quiet row above the stacks.
    private var reviewRow: some View {
        Button { set(.review) } label: {
            HStack(spacing: 12) {
                Image(systemName: "tray.full").font(.title3).foregroundStyle(t.accent)
                Text(model.reviewCount == 1 ? "1 save waiting in Review" : "\(model.reviewCount) saves waiting in Review")
                    .font(.subheadline.weight(.medium)).foregroundStyle(t.ink)
                Spacer()
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(t.inkMuted)
            }
            .padding(.horizontal, 14).frame(minHeight: 52)
            .background(t.paper)
            .overlay(alignment: .leading) { Rectangle().fill(t.accent).frame(width: 3) }
            .resting()
        }
        .buttonStyle(PressStyle())
    }

    private func count(_ n: Int, _ noun: String) -> String { n == 1 ? "1 \(noun)" : "\(n) \(noun)s" }

    /// Select mode: move or trash several saves at once.
    private var selectionBar: some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(destinations) { d in
                    Button(d.label) {
                        let ids = Array(selected)
                        Task {
                            let name = (try? await model.library?.put(ids, in: d.value)) ?? d.label
                            Haptic.dropped()
                            model.refresh()
                            model.show(ids.count == 1 ? "Moved to \(name)" : "Moved \(ids.count) saves to \(name)")
                            selected = []
                            selecting = false
                        }
                    }
                }
            } label: {
                Label("Move to…", systemImage: "folder").font(.headline).foregroundStyle(t.onAccent)
                    .frame(maxWidth: .infinity, minHeight: 54).background(t.accent, in: Capsule())
            }
            .disabled(selected.isEmpty)
            Button {
                let ids = Array(selected)
                Task {
                    try? await model.library?.trash(ids)
                    Haptic.trashed()
                    model.refresh()
                    model.show(ids.count == 1 ? "Moved to Trash" : "Moved \(ids.count) saves to Trash") {
                        try? await model.library?.restore(ids)
                        model.refresh()
                    }
                    selected = []
                    selecting = false
                }
            } label: {
                Image(systemName: "trash").font(.headline).foregroundStyle(t.stamp)
                    .frame(width: 54, height: 54).background(t.paper, in: Circle()).overlay(Circle().strokeBorder(t.rule))
            }
            .disabled(selected.isEmpty)
            .accessibilityLabel("Move \(selected.count) to Trash")
        }
        .padding(.horizontal, 16).padding(.bottom, 6)
        .background(alignment: .bottom) { BottomScrim() }
        .task { destinations = (try? await model.library?.destinations()) ?? [] }
    }

    private var dock: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.body.weight(.semibold)).foregroundStyle(t.inkMuted)
                TextField(model.saves.count == 1 ? "Search 1 save" : "Search \(model.saves.count) saves", text: $query)
                    .focused($searching)
                    .submitLabel(.search)
                    .foregroundStyle(t.ink)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(t.inkMuted) }
                        .accessibilityLabel("Clear search")
                        .frame(minWidth: 44, minHeight: 44)
                }
            }
            .padding(.horizontal, 18)
            .frame(minHeight: 54)
            .background(t.paper, in: Capsule())
            .overlay(Capsule().strokeBorder(t.rule, lineWidth: 0.75))
            .shadow(color: .black.opacity(0.14), radius: 12, y: 6)
            // The system Paste button reads the clipboard only when tapped, so iOS never asks to allow it.
            PasteButton(payloadType: URL.self) { urls in
                Task { await model.pasteLink(urls.first?.absoluteString) }
            }
            .labelStyle(.iconOnly)
            .buttonBorderShape(.circle)
            .controlSize(.extraLarge)
            .tint(t.accentForWhiteGlyph)
            .accessibilityLabel("Save the link you copied")
        }
        .padding(.horizontal, 16).padding(.bottom, 6)
        .background(alignment: .bottom) { BottomScrim() }
    }
}

/// An empty or problem state: one sentence, at most one action.
struct EmptyNote: View {
    let symbol: String
    let text: String
    var action: (() -> Void)?
    @Environment(\.ks) private var t
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 34, weight: .light)).foregroundStyle(t.inkMuted)
            Text(text).font(.system(.body, design: .serif)).foregroundStyle(t.ink).multilineTextAlignment(.center)
            if let action {
                Button("Import from Chrome", action: action).buttonStyle(.bordered).frame(minHeight: 44)
            }
        }
        .padding(.horizontal, 24).padding(.top, 60)
        .frame(maxWidth: .infinity)
    }
}
