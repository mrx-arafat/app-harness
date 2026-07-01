import Foundation

/// A single to-do item shown on the Today screen.
public struct TaskItem: Identifiable, Equatable {
    public let id: String
    public let title: String
    public var isDone: Bool

    public init(id: String, title: String, isDone: Bool = false) {
        self.id = id
        self.title = title
        self.isDone = isDone
    }
}

/// In-memory store the UI layer binds to. Kept intentionally free of debug
/// prints, hardcoded endpoints and empty catches so the quality scanner reports
/// zero hits against this fixture.
public struct TaskStore {
    public private(set) var items: [TaskItem]

    public static let seed: [TaskItem] = [
        TaskItem(id: "t1", title: "Water the plants"),
        TaskItem(id: "t2", title: "Review the sprint board", isDone: true),
        TaskItem(id: "t3", title: "Call the dentist"),
    ]

    public init(items: [TaskItem] = TaskStore.seed) {
        self.items = items
    }

    public var remaining: Int {
        items.filter { !$0.isDone }.count
    }

    public var summary: String {
        remaining == 0 ? "All clear" : "\(remaining) left"
    }

    public mutating func toggle(_ id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].isDone.toggle()
    }
}
