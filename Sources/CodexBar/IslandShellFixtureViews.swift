import SwiftUI

enum IslandShellFixtureLayout {
    static let compactSpacing: CGFloat = 8
    static let compactPetSize: CGFloat = 20
    static let compactSideWidth = IslandShellMetrics.compactSideWidth
    static let horizontalPadding: CGFloat = 12
    static let verticalPadding: CGFloat = 10
    static let usageHeight: CGFloat = 15
    static let primaryHeight: CGFloat = 60
    static let secondaryHeight: CGFloat = 28
}

struct IslandPixelPet: View {
    let tone: IslandShellTone
    let size: CGFloat

    private var color: Color {
        switch self.tone {
        case .idle: Color(red: 0.13, green: 0.77, blue: 0.36)
        case .working: Color(red: 0.23, green: 0.51, blue: 0.96)
        }
    }

    var body: some View {
        Canvas { context, canvasSize in
            let unit = min(canvasSize.width / 8, canvasSize.height / 8)
            let cells = [
                CGRect(x: 1, y: 2, width: 1, height: 1),
                CGRect(x: 4, y: 2, width: 1, height: 1),
                CGRect(x: 0, y: 3, width: 6, height: 2),
                CGRect(x: 1, y: 5, width: 2, height: 1),
                CGRect(x: 4, y: 5, width: 2, height: 1),
            ]
            for cell in cells {
                context.fill(
                    Path(CGRect(
                        x: cell.minX * unit,
                        y: cell.minY * unit,
                        width: cell.width * unit,
                        height: cell.height * unit)),
                    with: .color(self.color))
            }
            for eyeX in [1.0, 4.0] {
                context.fill(
                    Path(CGRect(
                        x: eyeX * unit,
                        y: 3 * unit,
                        width: unit,
                        height: unit)),
                    with: .color(.black))
            }
        }
        .frame(width: self.size, height: self.size)
        .shadow(color: self.color.opacity(0.65), radius: 3)
        .accessibilityHidden(true)
    }
}

struct IslandCompactFixtureView: View {
    let presentation: IslandShellPresentation

    private var sideWidth: CGFloat {
        (self.presentation.bodyWidth - self.presentation.anchorSize.width) / 2
    }

    var body: some View {
        ZStack {
            HStack(spacing: IslandShellFixtureLayout.compactSpacing) {
                IslandPixelPet(tone: .idle, size: IslandShellFixtureLayout.compactPetSize)
                Text(self.presentation.fixture.compactTitle)
                    .font(.custom(IslandShellFont.familyName, size: 11))
                    .foregroundStyle(.white.opacity(0.82))
                    .lineLimit(1)
            }
            .frame(width: self.sideWidth, alignment: .leading)
            .clipped()
            .position(x: self.sideWidth / 2, y: self.presentation.height / 2)

            Text("\(self.presentation.fixture.sessionCount)")
                .font(.custom(IslandShellFont.familyName, size: 9))
                .foregroundStyle(.white.opacity(0.52))
                .frame(width: self.sideWidth, alignment: .trailing)
                .position(
                    x: self.presentation.bodyWidth - self.sideWidth / 2,
                    y: self.presentation.height / 2)
        }
        .frame(width: self.presentation.bodyWidth, height: self.presentation.height)
    }
}

struct IslandExpandedFixtureView: View {
    let fixture: IslandShellFixture

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(self.fixture.usageText)
                .font(.custom(IslandShellFont.familyName, size: 9.5))
                .foregroundStyle(.white.opacity(0.62))
                .padding(.horizontal, 8)
                .frame(height: IslandShellFixtureLayout.usageHeight)
            IslandPrimarySessionFixtureView(session: self.fixture.primary)
            ForEach(self.fixture.secondary) { session in
                IslandSecondarySessionFixtureView(session: session)
            }
        }
        .padding(.horizontal, IslandShellFixtureLayout.horizontalPadding)
        .padding(.vertical, IslandShellFixtureLayout.verticalPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct IslandPrimarySessionFixtureView: View {
    let session: IslandShellSessionFixture

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            IslandPixelPet(tone: self.session.tone, size: 16)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(self.session.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                    Spacer(minLength: 4)
                    IslandSessionTag(text: self.session.agent)
                    IslandSessionTag(text: self.session.host)
                    Text(self.session.duration)
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.35))
                }
                if let prompt = self.session.prompt {
                    Text(prompt)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.40))
                        .lineLimit(1)
                }
                if let status = self.session.status {
                    Text(status)
                        .font(.system(size: 10))
                        .foregroundStyle(Color(red: 0.23, green: 0.51, blue: 0.96))
                        .lineLimit(1)
                }
            }
        }
        .padding(8)
        .frame(height: IslandShellFixtureLayout.primaryHeight)
        .contentShape(Rectangle())
    }
}

private struct IslandSecondarySessionFixtureView: View {
    let session: IslandShellSessionFixture

    private var dotColor: Color {
        switch self.session.tone {
        case .idle: Color(red: 0.13, green: 0.77, blue: 0.36)
        case .working: Color(red: 0.23, green: 0.51, blue: 0.96)
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(self.dotColor).frame(width: 6, height: 6)
            Text(self.session.title)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.70))
                .lineLimit(1)
            Spacer(minLength: 4)
            IslandSessionTag(text: self.session.agent)
            IslandSessionTag(text: self.session.host)
            Text(self.session.duration)
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.35))
        }
        .padding(.horizontal, 8)
        .frame(height: IslandShellFixtureLayout.secondaryHeight)
    }
}

private struct IslandSessionTag: View {
    let text: String

    var body: some View {
        Text(self.text)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.white.opacity(0.48))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
    }
}
