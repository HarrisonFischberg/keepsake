import UIKit
import SwiftUI
import UniformTypeIdentifiers
import KeepsakeKit
import KeepsakeUI

/// The Share Sheet way in. Saves first (one tap, no waiting), then a card shows where it went: flick
/// the slip to put it somewhere else, add a note, or undo. Stays open until you tap Done (or Undo).
final class ShareViewController: UIViewController {
    private let state = ShareState()

    override init(nibName: String?, bundle: Bundle?) {
        super.init(nibName: nibName, bundle: bundle)
        modalPresentationStyle = .overFullScreen
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        modalPresentationStyle = .overFullScreen
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        state.finish = { [weak self] in self?.extensionContext?.completeRequest(returningItems: nil) }
        let host = UIHostingController(rootView: ShareCard(state: state).keepsakeAppearance(Appearance.load()))
        host.view.backgroundColor = .clear
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        Task { await state.save(items: extensionContext?.inputItems as? [NSExtensionItem] ?? []) }
    }
}

@MainActor @Observable
final class ShareState {
    enum Phase { case saving, saved, duplicate, failed(String) }
    /// The two libraries a save can live in.
    enum Shelf: Hashable { case collections, lifestyle }
    static let review = "review"
    var phase: Phase = .saving
    var save: Save?
    var destinations: [Destination] = []
    /// Everything saved, for each group's cover and count.
    var saves: [Save] = []
    var destination: String?          // Destination.value, or `review`
    var destinationLabel = ""
    /// The library being looked through; nil shows the two library cards.
    var shelf: Shelf?
    var touched = false
    var note = ""
    var finish: () -> Void = {}
    private var library: Library?

    func save(items: [NSExtensionItem]) async {
        let shared = await SharedContent.read(from: items)
        do {
            let library = try Library()
            self.library = library
            var product: [String: Any]
            if let page = shared.page { product = page } else { product = await library.sharedProduct(url: shared.url, title: shared.title, text: shared.text) }
            // A screenshot or photo with no link: its picture and the text read from it, on this device.
            if shared.page == nil, shared.url == nil, let image = shared.image {
                product = await ImageCapture.product(from: image)
            }
            let result = try await library.capture(product: product)
            if let dup = result.duplicateOf {
                save = dup
                destinationLabel = result.destination ?? KindStyle(dup.kind).label
                phase = .duplicate
                return
            }
            guard let s = result.save else { phase = .failed("Keepsake couldn't read what was shared."); return }
            save = s
            Haptic.saved()
            phase = .saved
            destinations = (try? await library.destinations()) ?? []
            saves = (try? library.saves()) ?? []
            let here = s.hasOwnView ? "kind:\(s.kind)" : s.collectionId
            if let d = destinations.first(where: { $0.value == here }) {
                destination = d.value
                destinationLabel = d.label
            } else {
                destination = Self.review
                destinationLabel = "Review"
            }
            UIAccessibility.post(notification: .announcement, argument: "Saved to \(destinationLabel)")
        } catch {
            phase = .failed(error.localizedDescription)
            Haptic.refused()
        }
    }

    /// Which library it's in now, so that card wears the check.
    var shelfNow: Shelf? {
        guard let d = destinations.first(where: { $0.value == destination }) else { return nil }
        return d.group == "lifestyle" ? .lifestyle : .collections
    }

    func groups(_ shelf: Shelf) -> [Destination] { destinations.filter { $0.group == (shelf == .lifestyle ? "lifestyle" : "collection") } }

    /// What's already in a group (not counting this save), for its tile.
    func members(_ d: Destination) -> [Save] {
        saves.filter { $0.id != save?.id && (d.kind.map { k in $0.kind == k } ?? ($0.collectionId == d.value)) }
    }

    func members(_ shelf: Shelf) -> [Save] {
        saves.filter { $0.id != save?.id && (shelf == .lifestyle ? $0.hasOwnView : !($0.collectionId ?? "").isEmpty) }
    }

    func open(_ shelf: Shelf?) {
        touched = true
        Haptic.pageTurned()
        self.shelf = shelf
    }

    /// Puts it in a group, then shows the two libraries again with where it went.
    func put(_ d: Destination) { put(d.value, d.label) }

    private func put(_ value: String, _ label: String) {
        guard let save, let library else { return }
        touched = true
        destination = value
        destinationLabel = label
        shelf = nil
        Haptic.dropped()
        UIAccessibility.post(notification: .announcement, argument: "Going to \(label)")
        Task { _ = try? await library.put([save.id], in: value) }
    }

    /// Not sure yet: it waits in Review, where Keepsake suggests a home later.
    func toReview() {
        guard let save, let library, destination != Self.review else { shelf = nil; return }
        touched = true
        destination = Self.review
        destinationLabel = "Review"
        shelf = nil
        Haptic.settled()
        UIAccessibility.post(notification: .announcement, argument: "Going to Review")
        Task { try? await library.toReview([save.id]) }
    }

    func createCollection(_ name: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard let library, !name.isEmpty else { return }
        Task {
            guard let c = try? await library.createCollection(named: name) else { Haptic.refused(); return }
            destinations = (try? await library.destinations()) ?? destinations
            put(c.id, c.name)
        }
    }

    func undo() {
        guard let save, let library else { finish(); return }
        Haptic.undo()
        Task {
            try? await library.undoSave(save.id)
            finish()
        }
    }

    func done() {
        guard let save, let library, !note.trimmingCharacters(in: .whitespaces).isEmpty else { finish(); return }
        Task {
            try? await library.update(save.id, ["note": note])
            finish()
        }
    }
}

/// What the host app shared: Safari's page reading (ShareExtract.js, Chrome's extract.js), or a URL,
/// a title and any text from another app.
struct SharedContent {
    var page: [String: Any]?
    var image: UIImage?
    var url: String?
    var title: String?
    var text: String?

    static func read(from items: [NSExtensionItem]) async -> SharedContent {
        var out = SharedContent()
        for item in items {
            if out.title == nil, let t = item.attributedContentText?.string, !t.isEmpty { out.title = t }
            for provider in item.attachments ?? [] {
                if out.page == nil, provider.hasItemConformingToTypeIdentifier(UTType.propertyList.identifier),
                   let dict = try? await provider.loadItem(forTypeIdentifier: UTType.propertyList.identifier) as? NSDictionary,
                   let results = dict[NSExtensionJavaScriptPreprocessingResultsKey] as? [String: Any] {
                    if let json = results["product"] as? String, !json.isEmpty,
                       let product = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] {
                        out.page = product
                    }
                    out.url = out.url ?? (results["url"] as? String)
                    out.title = out.title ?? (results["title"] as? String)
                } else if out.url == nil, provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                          let url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL {
                    out.url = url.absoluteString
                } else if out.image == nil, provider.hasItemConformingToTypeIdentifier(UTType.image.identifier),
                          let item = try? await provider.loadItem(forTypeIdentifier: UTType.image.identifier) {
                    if let img = item as? UIImage { out.image = img }
                    else if let u = item as? URL, let data = try? Data(contentsOf: u) { out.image = UIImage(data: data) }
                    else if let data = item as? Data { out.image = UIImage(data: data) }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                          let text = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String {
                    // Many apps share a link inside text ("Look at this https://…").
                    if out.url == nil, let found = text.firstLink { out.url = found }
                    out.text = text
                }
            }
        }
        return out
    }
}

extension String {
    var firstLink: String? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        return detector?.firstMatch(in: self, range: NSRange(startIndex..., in: self))?.url?.absoluteString
    }
}

struct ShareCard: View {
    let state: ShareState
    @Environment(\.ks) private var t
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var appeared = false
    @State private var writing = false
    @State private var naming = false
    @State private var newName = ""
    @FocusState private var noteFocused: Bool

    // iOS presents a share extension as a full-height sheet, so the whole sheet is the table: the save
    // drawn as its object, and under the thumb the two libraries it can live in (Collections and
    // Lifestyle). Tap one to look through its groups and tap a group to put it there; Review is always
    // one tap away for when you're not sure.
    var body: some View {
        @Bindable var state = state
        ZStack {
            TableBackground()
            VStack(alignment: .leading, spacing: 16) {
                status
                if let save = state.save {
                    if state.shelf == nil {
                        Spacer(minLength: 4)
                        SaveObject(save)
                            .frame(maxWidth: 210)
                            .frame(maxWidth: .infinity)
                            .rotationEffect(.degrees(appeared || reduce ? -1.5 : -8))
                            .scaleEffect(appeared || reduce ? 1 : 0.85)
                            .opacity(appeared ? 1 : 0)
                            .transition(.opacity.combined(with: .scale(scale: 0.9)))
                        Spacer(minLength: 4)
                    } else {
                        compact(save).transition(.opacity)
                    }
                } else if case .saving = state.phase {
                    Spacer()
                    ProgressView().frame(maxWidth: .infinity)
                    Spacer()
                } else {
                    Spacer()
                }
                if case .saved = state.phase {
                    Group {
                        if let shelf = state.shelf { groups(shelf) } else { libraries }
                    }
                    .transition(reduce ? .opacity : .asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                                                 removal: .move(edge: .leading).combined(with: .opacity)))
                }
                if writing {
                    TextField("Add a note", text: $state.note, axis: .vertical)
                        .focused($noteFocused)
                        .font(KSFont.note)
                        .padding(12).background(t.paper, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(t.rule))
                }
                HStack(spacing: 10) {
                    if case .saved = state.phase, !writing {
                        secondary("Add a note", "square.and.pencil") {
                            state.touched = true
                            writing = true
                            noteFocused = true
                        }
                    }
                    PrimarySlab("Done", symbol: "checkmark") { state.done() }
                }
            }
            .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 12)
            .animation(KSMotion.or(KSMotion.sheet, reduce: reduce), value: state.shelf)
            .animation(KSMotion.or(KSMotion.settle, reduce: reduce), value: state.destination)
        }
        .simultaneousGesture(TapGesture().onEnded { state.touched = true })
        .onAppear { withAnimation(KSMotion.or(KSMotion.lift, reduce: reduce).delay(0.05)) { appeared = true } }
        .alert("New collection", isPresented: $naming) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) { newName = "" }
            Button("Create") { state.createCollection(newName); newName = "" }
        } message: { Text("It goes straight in.") }
    }

    @ViewBuilder private var status: some View {
        HStack(spacing: 8) {
            switch state.phase {
            case .saving:
                ProgressView().controlSize(.small)
                Text("Saving").font(.subheadline.weight(.semibold)).foregroundStyle(t.ink)
            case .saved:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(KindStyle("recipe").color)
                Text("Saved").font(.subheadline.weight(.semibold)).foregroundStyle(t.ink)
                if state.save?.isFinishing == true { Text("· finishing details").font(.subheadline).foregroundStyle(t.inkMuted) }
            case .duplicate:
                Image(systemName: "bookmark.fill").foregroundStyle(t.accent)
                Text("Already saved in \(state.destinationLabel)").font(.subheadline.weight(.semibold)).foregroundStyle(t.ink)
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(t.stamp)
                Text(message).font(.subheadline).foregroundStyle(t.ink)
            }
            Spacer()
            if case .saved = state.phase {
                Button("Undo") { state.undo() }
                    .font(.subheadline.weight(.semibold)).foregroundStyle(t.accent)
                    .frame(minWidth: 44, minHeight: 44)
            }
        }
        .frame(minHeight: 30)
    }

    /// While looking through a library: the save as a small card, so the groups get the room.
    private func compact(_ save: Save) -> some View {
        HStack(spacing: 12) {
            SaveImage(save, symbolSize: 18).frame(width: 52, height: 52).clipShape(RoundedRectangle(cornerRadius: 3))
            VStack(alignment: .leading, spacing: 2) {
                Text(save.title).font(KSFont.name(.headline)).foregroundStyle(t.ink).lineLimit(2)
                HStack(spacing: 5) {
                    Image(systemName: icon(state.destination)).imageScale(.small)
                    Text("In \(state.destinationLabel)").contentTransition(.opacity)
                }
                .font(.subheadline.weight(.medium)).foregroundStyle(tint(state.destination))
            }
            Spacer(minLength: 0)
        }
        .padding(10).background(t.paper).resting()
    }

    private func icon(_ value: String?) -> String {
        if value == ShareState.review { return "tray" }
        if let d = state.destinations.first(where: { $0.value == value }), let k = d.kind { return KindStyle(k).symbol }
        return "bag"
    }

    private func tint(_ value: String?) -> Color {
        if value == ShareState.review { return t.accent }
        if let d = state.destinations.first(where: { $0.value == value }), let k = d.kind { return KindStyle(k).color }
        return KindStyle("product").color
    }

    // MARK: the two libraries

    private var libraries: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Where does it live?").font(KSFont.name(.title3)).foregroundStyle(t.ink).accessibilityAddTraits(.isHeader)
                (Text(state.destination == ShareState.review ? "For now it's waiting in " : "Keepsake put it in ").foregroundStyle(t.inkMuted)
                 + Text(state.destinationLabel).foregroundStyle(tint(state.destination)).fontWeight(.semibold))
                    .font(.subheadline)
                    .contentTransition(.opacity)
            }
            HStack(spacing: 12) {
                libraryCard(.collections, "Collections", "Things to buy", symbol: "bag", tint: KindStyle("product").color)
                libraryCard(.lifestyle, "Lifestyle", "Recipes, places, workouts", symbol: "sparkles", tint: KindStyle("recipe").color)
            }
            reviewRow
        }
    }

    private func libraryCard(_ shelf: ShareState.Shelf, _ title: String, _ caption: String, symbol: String, tint: Color) -> some View {
        let here = state.shelfNow == shelf
        let count = state.groups(shelf).count
        return Button { state.open(shelf) } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    CoverFan(state.members(shelf), symbol: symbol, tint: tint, size: 40)
                    Spacer(minLength: 0)
                    if here {
                        Image(systemName: "checkmark.circle.fill").font(.title3).foregroundStyle(tint)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(KSFont.name(.title3)).foregroundStyle(t.ink)
                    Text(here ? state.destinationLabel : caption).font(.footnote).foregroundStyle(here ? tint : t.inkMuted).lineLimit(1)
                }
                HStack(spacing: 4) {
                    Text(count == 1 ? "1 group" : "\(count) groups")
                    Image(systemName: "chevron.right").imageScale(.small)
                }
                .font(.caption.weight(.medium)).foregroundStyle(t.inkMuted)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 168, alignment: .topLeading)
            .background {
                ZStack {
                    Rectangle().fill(t.paper)
                    if here { Rectangle().fill(tint.opacity(0.07)) }
                }
            }
            .overlay { Rectangle().strokeBorder(here ? tint.opacity(0.9) : t.rule, lineWidth: here ? 1.5 : 0.75) }
            .resting()
        }
        .buttonStyle(PressStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(here ? "It's in \(state.destinationLabel)" : caption)
        .accessibilityHint("Shows its groups.")
        .accessibilityAddTraits(here ? [.isButton, .isSelected] : .isButton)
    }

    /// Always there: not sure yet, so it waits in Review.
    private var reviewRow: some View {
        let here = state.destination == ShareState.review
        return Button { state.toReview() } label: {
            HStack(spacing: 12) {
                Image(systemName: here ? "tray.full.fill" : "tray").font(.body.weight(.medium)).foregroundStyle(t.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(here ? "Waiting in Review" : "Not sure? Put it in Review").font(.subheadline.weight(.semibold)).foregroundStyle(t.ink)
                    Text("Keepsake suggests a home for it later.").font(.caption).foregroundStyle(t.inkMuted)
                }
                Spacer(minLength: 0)
                if here { Image(systemName: "checkmark").font(.subheadline.weight(.bold)).foregroundStyle(t.accent) }
            }
            .padding(.horizontal, 14).frame(minHeight: 56)
            .background(Rectangle().strokeBorder(here ? t.accent : t.ink.opacity(0.28), style: StrokeStyle(lineWidth: 1, dash: here ? [] : [4, 3])))
            .background(here ? t.accent.opacity(0.08) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(here ? "Waiting in Review" : "Put it in Review")
        .accessibilityAddTraits(here ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: one library's groups

    private func groups(_ shelf: ShareState.Shelf) -> some View {
        let lifestyle = shelf == .lifestyle
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Button { state.open(nil) } label: {
                    Image(systemName: "chevron.left").font(.headline).foregroundStyle(t.ink)
                        .frame(width: 44, height: 44).background(t.paper, in: Circle()).overlay(Circle().strokeBorder(t.rule, lineWidth: 0.75))
                }
                .accessibilityLabel("Back")
                VStack(alignment: .leading, spacing: 0) {
                    Text(lifestyle ? "Lifestyle" : "Collections").font(KSFont.name(.title3)).foregroundStyle(t.ink).accessibilityAddTraits(.isHeader)
                    Text(lifestyle ? "Pick the view it belongs in" : "Pick a collection, or start one").font(.footnote).foregroundStyle(t.inkMuted)
                }
                .padding(.leading, 4)
                Spacer()
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 14)], spacing: 16) {
                    ForEach(state.groups(shelf)) { d in
                        let items = state.members(d)
                        let k = d.kind.map(KindStyle.init)
                        let here = state.destination == d.value
                        Button { state.put(d) } label: {
                            GroupTile(d.label, subtitle: items.isEmpty ? "Empty" : (items.count == 1 ? "1 save" : "\(items.count) saves"),
                                      cover: items.first(where: \.hasImage), symbol: k?.symbol ?? "bag",
                                      tint: k?.color ?? KindStyle("product").color, kind: d.kind, selected: here)
                                .overlay(alignment: .topLeading) {
                                    if here {
                                        Image(systemName: "checkmark.circle.fill").font(.title3)
                                            .foregroundStyle(k?.color ?? KindStyle("product").color, t.paper)
                                            .padding(12)
                                    }
                                }
                        }
                        .buttonStyle(PressStyle())
                    }
                    if !lifestyle {
                        Button { naming = true } label: { NewGroupTile("New collection") }
                            .buttonStyle(PressStyle())
                    }
                }
                .padding(.horizontal, 4).padding(.vertical, 8)
            }
            .scrollIndicators(.hidden)
            .frame(maxHeight: .infinity)
            reviewRow
        }
    }

    private func secondary(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(.subheadline.weight(.medium)).foregroundStyle(t.ink)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(RoundedRectangle(cornerRadius: 6).fill(t.paper).resting())
        }
        .buttonStyle(PressStyle())
    }
}
