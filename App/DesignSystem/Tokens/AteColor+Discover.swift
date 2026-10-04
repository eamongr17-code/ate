import SwiftUI
import UIKit

extension AtePalette {
    /// **The ask card's surface** (`discover.html` `.ask`) — a slip, whose pills keep the ground's field
    /// linen (`.pk{background:#E4DED4}` on the white card) in light, and take the slip's raised chip in
    /// dark, where the ground's field is the card's own plum and would vanish.
    static let askCard: AtePalette = {
        var palette = AtePalette.slip
        let light = UITraitCollection(userInterfaceStyle: .light)
        let linen = UIColor(AtePalette.automatic.field).resolvedColor(with: light)
        palette.field = Color(light: Color(uiColor: linen), dark: AtePalette.slip.field)
        return palette
    }()
}
