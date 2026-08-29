import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct AgentTaskHookInstallerTests {
    @Test
    func `installer writes provider files with restrictive permissions`() throws {
        let fixture = try AgentTaskHookInstallerFixture()
        defer { fixture.remove() }

        try fixture.installer.install(.claude)

        let settings = fixture.home.appendingPathComponent(".claude/settings.json")
        #expect(fixture.installer.inspect(.claude).document == .installed)
        let attributes = try FileManager.default.attributesOfItem(atPath: settings.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test
    func `removal preserves unrelated settings`() throws {
        let fixture = try AgentTaskHookInstallerFixture()
        defer { fixture.remove() }
        let settings = fixture.home.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(
            at: settings.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data(#"{"theme":"dark"}"#.utf8).write(to: settings)

        try fixture.installer.install(.claude)
        try fixture.installer.remove(.claude)

        let data = try Data(contentsOf: settings)
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(root["theme"] as? String == "dark")
        #expect(fixture.installer.inspect(.claude).document == .notInstalled)
    }
}

private struct AgentTaskHookInstallerFixture {
    let home: URL
    let installer: AgentTaskHookInstaller

    init() throws {
        self.home = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-agent-hooks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: self.home, withIntermediateDirectories: true)
        let helper = self.home.appendingPathComponent("CodexBarCLI")
        #expect(FileManager.default.createFile(atPath: helper.path, contents: Data()))
        self.installer = AgentTaskHookInstaller(homeDirectory: self.home, helperURL: helper)
    }

    func remove() {
        try? FileManager.default.removeItem(at: self.home)
    }
}
