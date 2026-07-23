import SwiftUI

@main
struct XFinderApp: App {
    @StateObject private var store: WorkspaceStore
    @StateObject private var speechController: ReadAloudController

    init() {
        let store = WorkspaceStore()
        let speechEngine = HybridReadAloudSpeechEngine(configProvider: { [weak store] in
            store?.settings.doubaoTTS ?? DoubaoTTSConfig()
        })
        let speechController = ReadAloudController(engine: speechEngine)
        speechController.onEvent = { [weak store] event in
            store?.handleReadAloudEvent(event)
        }
        _store = StateObject(wrappedValue: store)
        _speechController = StateObject(wrappedValue: speechController)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(speechController)
                .frame(minWidth: 980, minHeight: 620)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Folder") { PaneCommandCenter.post(.newFolder) }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("New Markdown File") { PaneCommandCenter.post(.newMarkdown) }
                    .keyboardShortcut("n", modifiers: [.command, .option])
            }

            CommandGroup(after: .undoRedo) {
                Button("Undo File Operation") { store.undoLastFileOperation() }
                    .disabled(!store.canUndoFileOperation)
                Button("Redo File Operation") { store.redoLastFileOperation() }
                    .disabled(!store.canRedoFileOperation)
            }

            CommandGroup(after: .pasteboard) {
                Button("Select All in Pane") { PaneCommandCenter.post(.selectAll) }
                Button("Copy Files") { PaneCommandCenter.post(.copySelection) }
                Button("Paste Files") { PaneCommandCenter.post(.paste) }
            }

            CommandMenu("File Actions") {
                Button("Open") { PaneCommandCenter.post(.openSelection) }
                Button("Quick Look") { PaneCommandCenter.post(.quickLook) }
                Button("Read Aloud") { PaneCommandCenter.post(.readAloudSelection) }
                if speechController.isActive {
                    Button(speechController.phase == .paused ? "Resume Reading" : "Pause Reading") {
                        speechController.togglePause()
                    }
                    .disabled(!speechController.canPauseOrResume)
                    Button("Stop Reading") { speechController.stop() }
                }
                Button("Get Info") { PaneCommandCenter.post(.getInfo) }
                    .keyboardShortcut("i", modifiers: .command)
                Button("Search Folder…") { PaneCommandCenter.post(.recursiveSearch) }
                    .keyboardShortcut("f", modifiers: [.command, .option])
                Divider()
                Button("Rename") { PaneCommandCenter.post(.renameSelection) }
                Button("Duplicate") { PaneCommandCenter.post(.duplicateSelection) }
                    .keyboardShortcut("d", modifiers: .command)
                Button("Compress") { PaneCommandCenter.post(.compressSelection) }
                Button("Reveal in Finder") { PaneCommandCenter.post(.revealSelection) }
                Divider()
                Button("Move to Trash") { PaneCommandCenter.post(.moveToTrash) }
                    .keyboardShortcut(.delete, modifiers: .command)
            }
        }

        WindowGroup("Markdown", for: MarkdownWindowRequest.self) { $request in
            if let request {
                MarkdownDocumentView(url: request.url)
                    .environmentObject(store)
                    .environmentObject(speechController)
            } else {
                Text(store.loc("未选择 Markdown 文档", "No Markdown document selected"))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 760, minHeight: 540)
            }
        }
        .defaultSize(width: 920, height: 700)
    }
}
