import Foundation

enum PaneCommand: String {
    case newFolder
    case newMarkdown
    case openSelection
    case duplicateSelection
    case renameSelection
    case getInfo
    case quickLook
    case readAloudSelection
    case recursiveSearch
    case selectAll
    case copySelection
    case paste
    case moveToTrash
    case revealSelection
    case compressSelection
}

extension Notification.Name {
    static let xfinderPaneCommand = Notification.Name("xfinderPaneCommand")
}

enum PaneCommandCenter {
    @MainActor
    static func post(_ command: PaneCommand) {
        NotificationCenter.default.post(name: .xfinderPaneCommand, object: command)
    }
}
