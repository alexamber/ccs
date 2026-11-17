import AppKit

/// An explicit user action; setting the path never reads or scans the folder.
final class FolderButton: NSButton {
    private let opener: (URL) -> Bool
    private(set) var folder: String?
    var onOpened: (() -> Void)?

    init(opener: @escaping (URL) -> Bool = { url in
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue else { return false }
        return NSWorkspace.shared.open(url)
    }) {
        self.opener = opener
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: "folder", accessibilityDescription: "Open folder in Finder")
        isBordered = false; contentTintColor = .secondaryLabelColor
        target = self; action = #selector(openFolder)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 20).isActive = true
        heightAnchor.constraint(equalToConstant: 20).isActive = true
        setFolder(nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    func setFolder(_ value: String?) {
        folder = value.flatMap { $0.hasPrefix("/") ? $0 : nil }
        isEnabled = folder != nil
        toolTip = folder.map { "Open folder in Finder\n" + $0 } ?? "Folder unavailable"
        setAccessibilityLabel(folder.map { "Open " + $0 + " in Finder" } ?? "Folder unavailable")
    }
    @objc func openFolder() {
        guard let folder else { return }
        if opener(URL(fileURLWithPath: folder, isDirectory: true)) { onOpened?() }
        else { toolTip = "Couldn’t open this folder. It may have moved.\n" + folder }
    }
}
