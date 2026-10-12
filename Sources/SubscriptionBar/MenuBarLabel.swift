import AppKit
import SwiftUI
import SubscriptionCore

/// The status item content. A MenuBarExtra label is flattened to one symbol and
/// one line of text, so stacked limits only survive as a pre-rendered template
/// image, which macOS tints for light and dark menu bars.
struct MenuBarLabel: View {
    static let height: CGFloat = 22
    /// Past this width macOS starts hiding other status items on smaller screens.
    static let comfortableWidth: CGFloat = 200
    let entries: [MenuBarEntry]
    let needsAttention: Bool

    var body: some View {
        HStack(spacing: 6) {
            // The icon is the only always-visible signal, so it must change shape
            // when something needs attention, not just fill level.
            Image(systemName: needsAttention ? "exclamationmark.triangle.fill" : "gauge.with.dots.needle.33percent")
            ForEach(entries) { entry in
                Group {
                    if entry.rows.isEmpty {
                        Text(entry.text)
                    } else {
                        HStack(spacing: 3) {
                            Text(entry.marker + entry.label)
                            Grid(alignment: .leading, horizontalSpacing: 3, verticalSpacing: 0) {
                                ForEach(entry.rows, id: \.window) { row in
                                    GridRow {
                                        Text(row.window)
                                        Text(row.value).gridColumnAlignment(.trailing)
                                    }
                                }
                            }.font(.system(size: 9, weight: .medium).monospacedDigit())
                        }
                    }
                }
                // Template images keep alpha, so a dimmed value stays dimmed in the menu bar.
                .opacity(entry.delayed ? 0.5 : 1)
            }
        }
        .font(Font(NSFont.menuBarFont(ofSize: 0) as CTFont).monospacedDigit())
        .frame(height: Self.height)
        .fixedSize()
    }

    func templateImage(scale: CGFloat) -> NSImage? {
        let renderer = ImageRenderer(content: self)
        renderer.scale = scale
        guard let image = renderer.nsImage else { return nil }
        image.isTemplate = true
        return image
    }
}
