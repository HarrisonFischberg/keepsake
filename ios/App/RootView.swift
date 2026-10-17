import SwiftUI
import KeepsakeKit
import KeepsakeUI

/// Where a link inside the app goes.
enum Route: Hashable {
    case kind(String)
    case review
    case collections
    case lifestyle
    case collection(String, String)
}

/// The app's frame: Home, Library and Places tabs, each with its own stack, and the Undo toast.
/// Search lives at the bottom of the Library (under the thumb), so it has no tab of its own (D20).
struct RootView: View {
    @Environment(LibraryModel.self) private var model
    @Environment(\.scenePhase) private var phase
    @Environment(\.horizontalSizeClass) private var size
    @State private var tab = "home"

    var body: some View {
        Group {
            if size == .regular { SplitRootView() } else { tabs }
        }
        // Near the bottom, under the thumb: above the tab bar, Library's search bar and a save's
        // action buttons, clear of the Dynamic Island and of titles and navigation buttons.
        .overlay(alignment: .bottom) {
            ToastView().frame(maxWidth: .infinity).padding(.horizontal, 16).padding(.bottom, 128)
        }
        .task { await model.start() }
        .onChange(of: phase) { _, now in
            if now == .active {
                model.refresh()
                model.finishSaves()
            }
        }
    }

    private var tabs: some View {
        TabView(selection: $tab) {
            Tab("Home", systemImage: "house", value: "home") { Stack(name: "home") { HomeScreen(zoom: $0) } }
                .badge(model.reviewCount)
            Tab("Library", systemImage: "books.vertical", value: "library") { Stack(name: "library") { LibraryScreen(zoom: $0) } }
            Tab("Places", systemImage: "map", value: "places") { Stack(name: "places") { PlacesScreen(zoom: $0) } }
        }
        .onChange(of: tab) { Perf.mark("tab \(tab)") }
        // keepsake://save/<id> (widgets): open that save in the Library.
        .onOpenURL { url in
            guard url.scheme == "keepsake", url.host() == "save", let id = url.pathComponents.last else { return }
            tab = "library"
            model.opening = (stack: "library", id: id)
        }
    }
}

/// A navigation stack that knows every destination, with a zoom namespace for card → detail.
struct Stack<Root: View>: View {
    let name: String
    @ViewBuilder let root: (Namespace.ID) -> Root
    @Namespace private var zoom
    @State private var path = NavigationPath()
    @Environment(LibraryModel.self) private var model

    var body: some View {
        NavigationStack(path: $path) {
            root(zoom)
                .navigationDestination(for: Save.self) { save in
                    SaveDetailScreen(save: save).navigationTransition(.zoom(sourceID: save.id, in: zoom))
                }
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .kind(let k): KindScreen(kind: k, zoom: zoom)
                    case .review: ReviewScreen(zoom: zoom)
                    case .collections: CollectionsScreen(zoom: zoom)
                    case .lifestyle: LifestyleScreen(zoom: zoom)
                    case .collection(let id, let name): CollectionScreen(id: id, name: name, zoom: zoom)
                    }
                }
        }
        .onChange(of: model.opening?.id) {
            guard let open = model.opening, open.stack == name, let save = model.saves.first(where: { $0.id == open.id }) else { return }
            path = NavigationPath()
            path.append(save)
            model.opening = nil
        }
    }
}

/// "Saved to Places · Undo". Stays 8 s; VoiceOver reads it politely.
struct ToastView: View {
    @Environment(LibraryModel.self) private var model
    @Environment(\.ks) private var t
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        @Bindable var model = model
        ZStack {
            if let toast = model.toast {
                HStack(spacing: 14) {
                    Text(toast.text).font(.subheadline.weight(.medium)).foregroundStyle(t.ink)
                    if let undo = toast.undo {
                        Button("Undo") {
                            Haptic.undo()
                            model.toast = nil
                            Task { await undo() }
                        }
                        .font(.subheadline.weight(.semibold))
                        .frame(minHeight: 44)
                    }
                }
                .padding(.horizontal, 18).frame(minHeight: 48)
                .background(t.paper, in: Capsule())
                .overlay(Capsule().strokeBorder(t.rule, lineWidth: 0.75))
                .shadow(color: .black.opacity(0.15), radius: 14, y: 6)
                .transition(reduce ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                .task(id: toast.id) {
                    UIAccessibility.post(notification: .announcement, argument: toast.text)
                    try? await Task.sleep(for: .seconds(8))
                    if model.toast?.id == toast.id { model.toast = nil }
                }
                .accessibilityElement(children: .contain)
            }
        }
        .animation(KSMotion.or(KSMotion.sheet, reduce: reduce), value: model.toast)
    }
}

/// A screen's big serif title and a quiet line under it.
struct ScreenHeader: View {
    let title: String
    var subtitle: String?
    @Environment(\.ks) private var t
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(KSFont.display()).foregroundStyle(t.ink).accessibilityAddTraits(.isHeader)
            if let subtitle { Text(subtitle).font(KSFont.note).foregroundStyle(t.inkMuted) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
    }
}

/// Saves as objects, linking to their screens.
struct SaveGrid: View {
    let saves: [Save]
    let zoom: Namespace.ID
    @Environment(LibraryModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.appearance) private var appearance
    var body: some View {
        Masonry(saves, columns: typeSize.isAccessibilitySize ? 1 : nil, minColumnWidth: appearance.density == "compact" ? 105 : 170) { save in
            NavigationLink(value: save) { SaveObject(save).matchedTransitionSource(id: save.id, in: zoom) }
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

/// Debug timing for the performance pass (prints only in Debug builds).
enum Perf {
    nonisolated(unsafe) static var last: (String, CFAbsoluteTime)?
    static func mark(_ what: String) {
        #if DEBUG
        last = (what, CFAbsoluteTimeGetCurrent())
        #endif
    }
    static func done(_ what: String) {
        #if DEBUG
        if let (from, t) = last { print("PERF \(from) → \(what): \(Int((CFAbsoluteTimeGetCurrent() - t) * 1000)) ms") }
        last = nil
        #endif
    }
}
