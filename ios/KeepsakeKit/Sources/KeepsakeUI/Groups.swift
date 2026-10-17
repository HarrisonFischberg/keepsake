#if canImport(UIKit)
import SwiftUI
import KeepsakeKit

/// A group of saves on the table (a collection, or a Lifestyle view): a small stack of cards with one
/// picture from the group on top, its name and how many it holds. Lifestyle groups wear their stamp.
public struct GroupTile: View {
    let title: String
    let subtitle: String
    let cover: Save?
    let symbol: String
    let tint: Color
    let kind: String?
    let selected: Bool
    @Environment(\.ks) private var t
    @Environment(\.accessibilityReduceMotion) private var reduce

    public init(_ title: String, subtitle: String, cover: Save?, symbol: String, tint: Color, kind: String? = nil, selected: Bool = false) {
        self.title = title; self.subtitle = subtitle; self.cover = cover; self.symbol = symbol; self.tint = tint; self.kind = kind; self.selected = selected
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    ZStack {
                        tint.opacity(0.10)
                        t.well.opacity(0.6)
                        if let cover, cover.hasImage { SaveImage(cover, showsSymbol: false) }
                        else { Image(systemName: symbol).font(.system(size: 30, weight: .light)).foregroundStyle(tint) }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    if let kind { Stamp(kind: kind, size: 28).padding(6) }
                }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(KSFont.name(.headline)).foregroundStyle(t.ink).lineLimit(2)
                Text(subtitle).font(.footnote).foregroundStyle(t.inkMuted).lineLimit(1)
            }
            .padding(.horizontal, 2)
        }
        .padding(8)
        .background(t.paper)
        .overlay {
            if selected { Rectangle().strokeBorder(tint, lineWidth: 2) }
        }
        // The cards underneath: a group is a stack, not a single save.
        .background {
            ZStack {
                Rectangle().fill(t.paper).rotationEffect(.degrees(reduce ? 0 : -2.4)).offset(x: -3, y: 4)
                Rectangle().fill(t.paper).rotationEffect(.degrees(reduce ? 0 : 1.6)).offset(x: 3, y: 2)
            }
            .shadow(color: .black.opacity(0.10), radius: 1, y: 0.5)
        }
        .resting()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(subtitle)")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// A tile that makes something new (a collection): a dashed outline where the next stack will sit.
public struct NewGroupTile: View {
    let title: String
    @Environment(\.ks) private var t
    public init(_ title: String) { self.title = title }
    public var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "plus").font(.title2.weight(.medium)).foregroundStyle(t.accent)
            Text(title).font(.subheadline.weight(.medium)).foregroundStyle(t.ink).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minHeight: 120)
        .background(Rectangle().strokeBorder(t.ink.opacity(0.28), style: StrokeStyle(lineWidth: 1.25, dash: [5, 4])))
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isButton)
    }
}

/// A few pictures from a group, fanned like cards in a hand: the face of a collapsed section.
public struct CoverFan: View {
    let saves: [Save]
    let symbol: String
    let tint: Color
    var size: CGFloat = 44
    @Environment(\.ks) private var t
    public init(_ saves: [Save], symbol: String, tint: Color, size: CGFloat = 44) { self.saves = saves; self.symbol = symbol; self.tint = tint; self.size = size }
    public var body: some View {
        let shown = Array(saves.filter(\.hasImage).prefix(3))
        ZStack {
            if shown.isEmpty {
                Image(systemName: symbol).font(.system(size: size * 0.42, weight: .medium)).foregroundStyle(tint)
                    .frame(width: size, height: size)
                    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            ForEach(Array(shown.enumerated()), id: \.element.id) { i, save in
                let angle = shown.count == 1 ? 0 : (Double(i) - Double(shown.count - 1) / 2) * 9
                SaveImage(save, symbolSize: size * 0.3)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                    .padding(2.5).background(t.paper)
                    .shadow(color: .black.opacity(0.16), radius: 1.5, y: 1)
                    .rotationEffect(.degrees(angle), anchor: .bottom)
                    .offset(x: CGFloat(i) * size * 0.32 - CGFloat(shown.count - 1) * size * 0.16)
                    .zIndex(Double(i))
            }
        }
        .frame(width: size * 1.7, height: size + 10)
        .accessibilityHidden(true)
    }
}
#endif
