
import SwiftData

enum Persistence {
    static let container: ModelContainer = {
        let schema = Schema([Book.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("创建 ModelContainer 失败：\(error)")
        }
    }()
}
