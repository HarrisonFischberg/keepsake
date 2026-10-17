import SwiftUI
import KeepsakeKit
import KeepsakeUI

/// Lifestyle: every Lifestyle view that has saves (Places, Recipes, Workouts…), each a stack you open.
struct LifestyleScreen: View {
    let zoom: Namespace.ID
    @Environment(LibraryModel.self) private var model

    var body: some View {
        ZStack {
            TableBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ScreenHeader(title: "Lifestyle", subtitle: "Places, recipes, workouts and more")
                    if model.saves.contains(where: \.hasOwnView) {
                        LifestyleTiles()
                    } else {
                        EmptyNote(symbol: "sparkles", text: "Nothing here yet. Share a recipe, a place or a workout to Keepsake and it lands here.")
                    }
                }
                .padding(.horizontal, 18).padding(.bottom, 40)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The grid both pages and the Library use: two stacks across on iPhone, more on iPad.
let groupColumns = [GridItem(.adaptive(minimum: 150), spacing: 16)]

/// Each Lifestyle view with saves, in Chrome's order, as a stack linking to its view.
struct LifestyleTiles: View {
    @Environment(LibraryModel.self) private var model

    var body: some View {
        LazyVGrid(columns: groupColumns, spacing: 20) {
            ForEach(KindStyle.lifestyle.filter { k in model.saves.contains { $0.kind == k } }, id: \.self) { kind in
                let items = model.saves.filter { $0.kind == kind }
                let k = KindStyle(kind)
                NavigationLink(value: Route.kind(kind)) {
                    GroupTile(k.plural, subtitle: items.count == 1 ? "1 save" : "\(items.count) saves",
                              cover: items.first(where: \.hasImage), symbol: k.symbol, tint: k.color, kind: kind)
                }
                .buttonStyle(PressStyle())
            }
        }
    }
}

/// Each collection as a stack with one of its pictures on top, linking to the collection. Pinned
/// collections come first, then your order (Chrome's).
struct CollectionTiles: View {
    let collections: [SaveCollection]
    var onNew: (() -> Void)?
    @Environment(LibraryModel.self) private var model

    var body: some View {
        LazyVGrid(columns: groupColumns, spacing: 20) {
            ForEach(collections) { c in
                let items = model.saves.filter { $0.collectionId == c.id }
                NavigationLink(value: Route.collection(c.id, c.name)) {
                    GroupTile(c.name, subtitle: items.count == 1 ? "1 save" : "\(items.count) saves",
                              cover: items.first(where: \.hasImage), symbol: c.pinned == true ? "pin" : "bag", tint: KindStyle("product").color)
                }
                .buttonStyle(PressStyle())
            }
            if let onNew {
                Button(action: onNew) { NewGroupTile("New collection") }
                    .buttonStyle(PressStyle())
            }
        }
    }
}

/// A section of the Library: its name, how many it holds, and its stacks.
struct GroupSection<Content: View>: View {
    let title: String
    let detail: String
    @ViewBuilder let content: Content
    @Environment(\.ks) private var t

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(KSFont.name(.title2)).foregroundStyle(t.ink).accessibilityAddTraits(.isHeader)
                Spacer()
                Text(detail).font(.footnote).foregroundStyle(t.inkMuted)
            }
            content
        }
    }
}
