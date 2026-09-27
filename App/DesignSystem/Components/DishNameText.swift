import AteKit
import SwiftUI

/// **A dish's name with its dietary chips riding on its last line** — the slip row's own
/// ``DietTagRun`` (`DietTagsB`: 6 after the name, 4 apart, lifted 3), for every other row that names
/// a dish: the place menu, a search result, the dish page. One `Text`, so a chip wraps with the word
/// it follows; the chips are real glyphs and scale with Dynamic Type.
struct DishNameText: View {
    let name: String
    let tags: [DietTag]
    let style: AteTextStyle
    /// Linen on paper; the ground's `field` tone on the linen ground (``DietTagChip/fill``).
    var chipFill: Color = AteColor.ground

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        var text = Text(name)
        if tags.isEmpty == false {
            text = Text("\(text)\(DietTagRun.text(tags: tags, dynamicTypeSize: dynamicTypeSize))")
        }
        return text
            .ateText(style)
            .textRenderer(DietTagRun.Renderer(dynamicTypeSize: dynamicTypeSize, fill: chipFill))
            .accessibilityLabel(([name] + tags.map(\.spokenName)).joined(separator: ", "))
    }
}

/// **A dish's chips on their own**, 4 apart — where the name is a title set on its own and the
/// chips sit beside the numbers under it (the dish page).
struct DietTagChips: View {
    let tags: [DietTag]
    var fill: Color = AteColor.ground

    var body: some View {
        HStack(spacing: TokenPillMetrics.dietGapBetween) {
            ForEach(tags, id: \.self) { DietTagChip(tag: $0, fill: fill) }
        }
    }
}
