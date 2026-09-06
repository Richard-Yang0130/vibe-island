import CodexBarCore
import Testing
@testable import CodexBar

struct IslandAttentionLifecycleTests {
    @Test
    func `completion waits then collapses only without ongoing interaction`() {
        func allowed(_ elapsed: Double, pointer: Bool = false, focus: Bool = false, pinned: Bool = false) -> Bool {
            IslandScenePolicy.canAutomaticallyCollapse(
                scene: .done,
                status: .completed,
                hasPendingApproval: false,
                pointerInside: pointer,
                keyboardFocus: focus,
                pinned: pinned,
                elapsed: elapsed)
        }
        #expect(!allowed(2.19))
        #expect(allowed(2.2))
        #expect(!allowed(3, pointer: true))
        #expect(!allowed(3, focus: true))
        #expect(!allowed(3, pinned: true))
        #expect(allowed(3))
    }

    @Test
    func `attention stays visible after pointer exits`() {
        for status in [AgentTaskStatus.needsApproval, .failed, .interrupted, .disconnected] {
            #expect(!IslandScenePolicy.canAutomaticallyCollapse(
                scene: .overview,
                status: status,
                hasPendingApproval: false,
                pointerInside: false,
                keyboardFocus: false,
                pinned: false,
                elapsed: 10))
        }
        for scene in [IslandScene.approval, .ask] {
            #expect(!IslandScenePolicy.canAutomaticallyCollapse(
                scene: scene,
                status: .running,
                hasPendingApproval: false,
                pointerInside: false,
                keyboardFocus: false,
                pinned: false,
                elapsed: 10))
        }
        #expect(!IslandScenePolicy.canAutomaticallyCollapse(
            scene: .done,
            status: .completed,
            hasPendingApproval: true,
            pointerInside: false,
            keyboardFocus: false,
            pinned: false,
            elapsed: 10))
        #expect(IslandScenePolicy.canAutomaticallyCollapse(
            scene: .overview,
            status: .running,
            hasPendingApproval: false,
            pointerInside: false,
            keyboardFocus: false,
            pinned: false,
            elapsed: 10))
    }

    @Test
    func `new approvals can interrupt expanded scenes and acknowledgement`() {
        for current in [IslandScene.compact, .overview, .done, .ask, .ack, .approval] {
            #expect(IslandScenePolicy.canPresentAttention(.approval, from: current))
            #expect(IslandScenePolicy.canPresentAttention(
                IslandScenePolicy.autoRaise(for: .needsApproval),
                from: current))
        }
    }

    @Test
    func `routine updates do not interrupt approval or answer handling`() {
        for current in [IslandScene.overview, .done, .ask, .ack, .approval] {
            for status in [AgentTaskStatus.completed, .running, .idle] {
                #expect(!IslandScenePolicy.canPresentAttention(
                    IslandScenePolicy.autoRaise(for: status),
                    from: current))
            }
        }
        #expect(IslandScenePolicy.canPresentAttention(.done, from: .compact))
        #expect(!IslandScenePolicy.canPresentAttention(.approval, from: .dormant))
    }

    @Test
    func `periodic refresh cannot raise an already presented event`() {
        var presented = IslandPresentedAttention()
        let raised = ["event:codex:a", "event:codex:a", "approval:claude:b", "event:codex:a", "event:codex:c"]
            .map { presented.markIfNew($0) }
        #expect(raised == [true, false, true, false, true])
    }
}
