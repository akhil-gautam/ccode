import AppKit
import CoreText
import SwiftUI

enum SidebarTypography {
    private static let registered: Bool = {
        let url = Bundle.main.url(forResource: "Inter-Regular", withExtension: "otf")
            ?? Bundle.module.url(forResource: "Inter-Regular", withExtension: "otf")
        guard let url else { return false }
        return CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }()

    static func nativeFont(_ size: CGFloat) -> NSFont {
        _ = registered
        return NSFont(name: "Inter-Regular", size: size) ?? .systemFont(ofSize: size)
    }

    static func font(_ size: CGFloat) -> Font {
        .custom(nativeFont(size).fontName, fixedSize: size).weight(.regular)
    }
}
