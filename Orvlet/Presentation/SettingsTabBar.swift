import SwiftUI

/// One moving selection surface; labels and hit regions never move with it.
struct SettingsTabBar: View {
    static let titles = ["General", "Appearance", "Models", "Access", "Data"]
    @Binding var selection: Int
    let accent: Color
    let reducedMotion: Bool
    @Environment(\.colorScheme) private var scheme
    @FocusState private var focusedTab: Int?

    var body: some View {
        GeometryReader { geometry in
            let width = (geometry.size.width - 6) / CGFloat(Self.titles.count)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(scheme == .dark ? Color.white.opacity(0.10) : Color.white)
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(accent.opacity(scheme == .dark ? 0.24 : 0.14), lineWidth: 0.5)
                    }
                    .shadow(color: .black.opacity(scheme == .dark ? 0.12 : 0.06), radius: 2, y: 1)
                    .frame(width: width, height: 30)
                    .offset(x: CGFloat(selection) * width)
                    .animation(CalmMotion.layout(reduced: reducedMotion), value: selection)
                    .allowsHitTesting(false).accessibilityHidden(true)
                HStack(spacing: 0) {
                    ForEach(Self.titles.indices, id: \.self) { index in
                        Button {
                            guard selection != index else { return }
                            selection = index
                        } label: {
                            Text(Self.titles[index])
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(
                                    selection == index
                                        ? CalmVisualStyle.tint(accent, scheme: scheme) : Color.primary.opacity(0.7)
                                )
                                .frame(width: width, height: 30)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .focused($focusedTab, equals: index)
                        .accessibilityIdentifier("settings-tab-\(index)")
                        .accessibilityAddTraits(selection == index ? [.isSelected] : [])
                    }
                }
            }.padding(3)
        }
        .frame(height: 36)
        .background(.primary.opacity(scheme == .dark ? 0.07 : 0.045), in: RoundedRectangle(cornerRadius: 11))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Settings tabs")
        .onMoveCommand { direction in
            let next: Int
            switch direction {
            case .left: next = max(0, selection - 1)
            case .right: next = min(Self.titles.count - 1, selection + 1)
            default: return
            }
            selection = next
            focusedTab = next
        }
    }
}
