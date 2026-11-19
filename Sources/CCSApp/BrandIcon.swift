import AppKit

enum BrandIcon {
    static func resource(_ name: String) -> NSImage? {
        let url = Bundle.main.url(forResource: name, withExtension: "png")
            ?? Bundle.module.url(forResource: name, withExtension: "png")
        return url.flatMap { NSImage(contentsOf: $0) }
    }
    static func image(template: Bool = false, size: CGFloat = 24) -> NSImage {
        let image = resource(template ? "UnicornTemplate" : "Unicorn")
            ?? NSImage(systemSymbolName: "sparkles", accessibilityDescription: "CCS")!
        image.size = NSSize(width: size, height: size)
        image.isTemplate = template
        image.accessibilityDescription = "CCS unicorn"
        return image
    }
}
