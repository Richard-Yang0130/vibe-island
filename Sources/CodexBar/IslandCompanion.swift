import CodexBarCore
import Foundation

@MainActor
final class IslandCompanionAssignments {
    static let shared = IslandCompanionAssignments()
    private let defaults: UserDefaults
    private let key = "islandCompanionAssignments.v1"
    private var assignments: [String: Int]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.assignments = (defaults.dictionary(forKey: self.key) ?? [:]).compactMapValues {
            guard let value = $0 as? Int, (0..<10).contains(value) else { return nil }
            return value
        }
    }

    func assign(keys: [String]) -> [String: Int] {
        let active = Set(keys)
        var counts = Array(repeating: 0, count: 10)
        for id in active {
            if let index = self.assignments[id] { counts[index] += 1 }
        }
        var changed = false
        for id in active.sorted() where self.assignments[id] == nil {
            let index = counts.indices.min { counts[$0] < counts[$1] } ?? 0
            self.assignments[id] = index
            counts[index] += 1
            changed = true
        }
        // ponytail: historical bindings grow with task count; keep them so returning tasks never change identity.
        if changed { self.defaults.set(self.assignments, forKey: self.key) }
        return self.assignments.filter { active.contains($0.key) }
    }
}

enum IslandCompanionMotion {
    static func frame(status: AgentTaskStatus, elapsed: TimeInterval, reduceMotion: Bool) -> Int {
        switch status {
        case .needsApproval: return 3
        case .failed: return 5
        case .completed: return reduceMotion || elapsed >= 0.9 ? 0 : 4
        case .idle, .interrupted, .disconnected: return 0
        case .running:
            guard !reduceMotion, elapsed.isFinite else { return 0 }
            let tick = Int((max(0, elapsed).truncatingRemainder(dividingBy: 1.2) + 0.000001) / 0.2)
            return tick == 1 ? 1 : tick == 3 ? 2 : 0
        }
    }
}
