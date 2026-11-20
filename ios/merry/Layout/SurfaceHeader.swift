import SwiftUI

/// The one header every open surface gets (agent, shell, browser), shaped
/// like an iOS navigation bar: the switcher on the left, title and a one-line
/// status in the middle, a single ••• menu on the right. Nothing else.
struct SurfaceHeader<MenuItems: View>: View {
    let title: String
    /// "Working · claude", "Needs approval", "Done · 3h ago", "zsh".
    let subtitle: String
    /// Speech input is recording (volume buttons): the subtitle says so.
    var isRecording = false
    /// "2/7": where this surface sits among the workspace's surfaces.
    let position: String
    /// Another surface is waiting on you: a small orange dot on the grid button.
    let othersNeedYou: Bool
    let onOpenSwitcher: () -> Void
    /// The ••• menu is opening: the layout lowers the keyboard.
    var onOpenMenu: () -> Void = {}
    @ViewBuilder let menuItems: () -> MenuItems

    var body: some View {
        ZStack {
            VStack(spacing: 1) {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                subtitleView
            }
            // Clear of the side buttons, so a long title truncates instead
            // of running under them.
            .padding(.horizontal, 84)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            HStack {
                gridButton
                Spacer()
                Menu(content: menuItems) {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 22, weight: .regular))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                // A Menu label takes the accent colour otherwise; the header
                // carries no colour but the needs-you dot.
                .tint(Color(white: 0.6))
                // A tap on the label also opens the menu; it fires alongside.
                .simultaneousGesture(TapGesture().onEnded { onOpenMenu() })
                .accessibilityLabel("More")
            }
            .padding(.horizontal, 8)
        }
        .frame(height: 52)
    }

    @ViewBuilder
    private var subtitleView: some View {
        if isRecording {
            HStack(spacing: 5) {
                Circle().fill(Color.red).frame(width: 6, height: 6)
                Text("Listening…")
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
        } else if !subtitle.isEmpty {
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                // Static on purpose: a pulse that repeats forever redraws the
                // header every frame for as long as an agent works. The
                // subtitle's "Working" and the chat's spinner say it.
        }
    }

    private var gridButton: some View {
        Button(action: onOpenSwitcher) {
            HStack(spacing: 5) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 17, weight: .regular))
                    .overlay(alignment: .topTrailing) {
                        if othersNeedYou {
                            Circle()
                                .fill(Theme.c.attention)
                                .frame(width: 8, height: 8)
                                .overlay(Circle().stroke(Theme.c.background, lineWidth: 1.5))
                                .offset(x: 4, y: -3)
                        }
                    }
                Text(position)
                    .font(.footnote.monospacedDigit())
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(othersNeedYou ? "Show all surfaces, some need you" : "Show all surfaces")
        .accessibilityValue(position)
    }
}
