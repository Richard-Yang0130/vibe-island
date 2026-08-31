import CoreText
import Foundation

enum IslandShellFont {
    static let familyName = "Departure Mono"

    static var fontURL: URL? {
        Bundle.module.url(
            forResource: "DepartureMono-Regular",
            withExtension: "otf")
    }

    static var licenseURL: URL? {
        Bundle.module.url(
            forResource: "DepartureMono-OFL",
            withExtension: "txt")
    }

    private static let didRegister: Bool = {
        guard let fontURL else { return false }
        return CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, nil)
    }()

    static func register() {
        _ = self.didRegister
    }
}
