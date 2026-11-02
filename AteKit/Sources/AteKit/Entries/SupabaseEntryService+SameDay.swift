import Foundation
import Supabase

extension SupabaseEntryService {
    /// `my_same_day_entry` (0103): `[]` = none that day, so the post is a new entry.
    public func sameDayEntry(restaurantID: UUID, at: Date) async throws -> EntryCard? {
        let data = try await api.supabase
            .rpc("my_same_day_entry", params: [
                "p_restaurant_id": AnyJSON.string(restaurantID.uuidString.lowercased()),
                "p_at": AnyJSON.string(PostgRESTTimestamp.string(from: at))
            ])
            .execute()
            .data
        return try PostgRESTDate.decoder.decode([EntryCard].self, from: data).first
    }
}
