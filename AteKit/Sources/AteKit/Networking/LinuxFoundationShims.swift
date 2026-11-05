import Foundation
#if !canImport(Darwin)
import Supabase
import Synchronization
#endif

// Linux only: lets `swift test` run in cloud containers and the Linux CI job. Apple's Foundation
// already has these; swift-corelibs-foundation does not. Nothing here compiles into the app.
#if !canImport(Darwin)
extension Array {
    /// Darwin Foundation's `move(fromOffsets:toOffset:)`: the elements at `source` land, in order,
    /// before the element that was at `destination`.
    mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moving = source.map { self[$0] }
        let before = source.filter { $0 < destination }.count
        for index in source.reversed() { remove(at: index) }
        insert(contentsOf: moving, at: destination - before)
    }
}
#endif

#if !canImport(Darwin)
/// A session store for Linux test runs, which have no keychain.
final class MemorySessionStorage: AuthLocalStorage {
    private let items = Mutex<[String: Data]>([:])
    func store(key: String, value: Data) throws { items.withLock { $0[key] = value } }
    func retrieve(key: String) throws -> Data? { items.withLock { $0[key] } }
    func remove(key: String) throws { _ = items.withLock { $0.removeValue(forKey: key) } }
}
#endif
