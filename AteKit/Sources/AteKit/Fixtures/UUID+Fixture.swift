import Foundation

extension UUID {
    /// **The same seed is the same id every launch** — the preview data's own ids. Letter tiles,
    /// avatars and photo tilts take their look from the id's bytes, so a fixture minted with `UUID()`
    /// drew differently on every launch and the screen snapshots compared two different pictures of
    /// the same page. (The app's gallery fixtures have their own copy, `UUID.fixture` in
    /// `AteSlipFixtures`, compiled into Beta as well.)
    static func fixture(_ seed: String) -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        for (offset, byte) in seed.utf8.enumerated() {
            bytes[offset % 16] = bytes[offset % 16] &* 31 &+ byte &+ UInt8(truncatingIfNeeded: offset)
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
