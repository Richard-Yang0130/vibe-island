import AppKit
import CodexBarCore
import SwiftUI
import Testing
@testable import CodexBar

@MainActor
struct IslandCompanionRenderingTests {
    @Test
    func `ten companions render without provider access`() throws {
        guard let path = ProcessInfo.processInfo.environment["VIBEISLAND_SNAPSHOT_DIR"] else { return }
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let grid = LazyVGrid(columns: Array(repeating: GridItem(.fixed(110)), count: 5)) {
            ForEach(0..<10) { index in
                IslandCompanionView(index: index, status: .running, reduceMotion: true, size: 100)
            }
        }
        .padding(20)
        .background(.black)
        let renderer = ImageRenderer(content: grid)
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        let data = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try data.write(to: directory.appendingPathComponent("native-ten-companions.png"))
    }
}
