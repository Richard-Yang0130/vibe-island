import AppKit
import CodexBarCore
import SwiftUI

extension EnvironmentValues {
    @Entry var islandCompanionVisible: Bool = true
}

@MainActor
enum IslandCompanionArtwork {
    struct Frame: Decodable {
        let x: CGFloat
        let y: CGFloat
    }

    struct Entry: Decodable {
        let sheet: String
        let frames: [Frame]
    }

    static let bundle: Bundle = {
        if let url = Bundle.main.url(forResource: "CodexBar_CodexBar", withExtension: "bundle"),
           let bundle = Bundle(url: url) { return bundle }
        return Bundle.module
    }()

    static let entries: [Entry] = {
        guard let url = IslandCompanionArtwork.bundle.url(forResource: "keyboard-squad", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([Entry].self, from: data),
              entries.count == 10,
              entries.allSatisfy({ $0.frames.count == 6 }) else { return [] }
        return entries
    }()

    private static var images: [Int: NSImage] = [:]

    static func image(index: Int) -> NSImage? {
        if let image = self.images[index] { return image }
        guard self.entries.indices.contains(index),
              let url = self.bundle.url(forResource: self.entries[index].sheet, withExtension: nil),
              let image = NSImage(contentsOf: url) else { return nil }
        self.images[index] = image
        return image
    }
}

/// Fixed body with local paw overlays; only visible, running companions schedule frame updates.
struct IslandCompanionView: View {
    let index: Int
    let status: AgentTaskStatus
    let reduceMotion: Bool
    var size: CGFloat = 40
    var statusUpdatedAt: Date?

    @Environment(\.islandCompanionVisible) private var visible
    @State private var frame = 0

    private var animationKey: String {
        let completedAt = self.status == .completed ? self.statusUpdatedAt?.timeIntervalSince1970 ?? 0 : 0
        return "\(self.index):\(self.status):\(self.reduceMotion):\(self.visible):\(completedAt)"
    }

    var body: some View {
        Group {
            if let image = IslandCompanionArtwork.image(index: self.index) {
                ZStack(alignment: .topLeading) {
                    self.pose(image, frame: self.status == .running ? 0 : self.frame)
                    if self.status == .running, self.frame != 0 {
                        self.pose(image, frame: self.frame)
                            .mask {
                                Path { path in
                                    path.addRect(CGRect(
                                        x: self.size * 0.17,
                                        y: self.size * 0.58,
                                        width: self.size * 0.28,
                                        height: self.size * 0.27))
                                    path.addRect(CGRect(
                                        x: self.size * 0.58,
                                        y: self.size * 0.58,
                                        width: self.size * 0.29,
                                        height: self.size * 0.27))
                                }
                            }
                    }
                }
            } else {
                Image(systemName: "keyboard")
                    .font(.system(size: self.size * 0.5))
                    .foregroundStyle(self.status.islandColor.color)
            }
        }
        .frame(width: self.size, height: self.size)
        .clipped()
        .accessibilityHidden(true)
        .transaction { $0.animation = nil }
        .task(id: self.animationKey) {
            let started = self.status == .completed ? (self.statusUpdatedAt ?? Date()) : Date()
            repeat {
                guard !Task.isCancelled else { return }
                self.frame = IslandCompanionMotion.frame(
                    status: self.status,
                    elapsed: Date().timeIntervalSince(started),
                    reduceMotion: self.reduceMotion)
                guard self.visible, !self.reduceMotion,
                      self.status == .running || (self.status == .completed && self.frame != 0)
                else { return }
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            } while !Task.isCancelled
        }
    }

    private func pose(_ image: NSImage, frame: Int) -> some View {
        let offset = IslandCompanionArtwork.entries[self.index].frames[frame]
        let top = max(0, CGFloat(frame / 3) - offset.y) * self.size
        let left = max(0, CGFloat(frame % 3) - offset.x) * self.size
        return Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .frame(width: self.size * 3, height: self.size * 2)
            .offset(x: -offset.x * self.size, y: -offset.y * self.size)
            .frame(width: self.size, height: self.size, alignment: .topLeading)
            .clipped()
            .mask(alignment: .topLeading) {
                Rectangle()
                    .frame(width: self.size - left, height: self.size - top)
                    .offset(x: left, y: top)
            }
    }
}
