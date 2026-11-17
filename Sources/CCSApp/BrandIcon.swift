import AppKit

enum BrandIcon {
    static func image(template: Bool = false, size: CGFloat = 24) -> NSImage {
        let name = template ? "UnicornTemplate" : "Unicorn"
        let url = Bundle.main.url(forResource: name, withExtension: "png")
            ?? Bundle.module.url(forResource: name, withExtension: "png")
        let image = url.flatMap { NSImage(contentsOf: $0) }
            ?? NSImage(systemSymbolName: "sparkles", accessibilityDescription: "CCS")!
        image.size = NSSize(width: size, height: size)
        image.isTemplate = template
        image.accessibilityDescription = "CCS unicorn"
        return image
    }
}
