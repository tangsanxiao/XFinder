import Foundation

struct SessionMarkdownLimits: Equatable, Sendable {
    var maximumMessages = 400
    var maximumTotalCharacters = 300_000
    var maximumCharactersPerTurn = 60_000
    var maximumBlocksPerTurn = 300

    static let standard = SessionMarkdownLimits()
}

struct SessionMarkdownTurn: Identifiable, Equatable, Sendable {
    let id: Int
    let role: SessionMessage.Role
    let document: MarkdownRenderDocument
}

struct SessionMarkdownTranscript: Equatable, Sendable {
    let turns: [SessionMarkdownTurn]
    let wasTruncated: Bool
}

private struct SessionSourceTurn: Sendable {
    let id: Int
    let role: SessionMessage.Role
    var parts: [String]
}

enum SessionMarkdownRendering {
    static func render(
        _ transcript: SessionTranscript,
        limits: SessionMarkdownLimits = .standard
    ) async -> SessionMarkdownTranscript {
        let worker = Task.detached(priority: .userInitiated) {
            renderSynchronously(transcript, limits: limits)
        }
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    static func renderSynchronously(
        _ transcript: SessionTranscript,
        limits: SessionMarkdownLimits = .standard
    ) -> SessionMarkdownTranscript {
        var remainingCharacters = max(0, limits.maximumTotalCharacters)
        var rendered: [SessionMarkdownTurn] = []
        var wasTruncated = transcript.wasTruncated
        let boundedMessages = Array(transcript.messages.prefix(max(0, limits.maximumMessages)))
        let sourceTurns = groupedTurns(from: boundedMessages)

        for turn in sourceTurns {
            guard !Task.isCancelled, remainingCharacters > 0 else {
                wasTruncated = true
                break
            }
            let characterLimit = min(max(0, limits.maximumCharactersPerTurn), remainingCharacters)
            let combined = boundedText(from: turn.parts, maximumCharacters: characterLimit)
            if combined.wasTruncated { wasTruncated = true }

            var markdownLimits = MarkdownDocumentLimits.standard
            markdownLimits.maximumPreviewCharacters = characterLimit
            markdownLimits.maximumBlocks = max(1, limits.maximumBlocksPerTurn)
            markdownLimits.maximumTableRows = min(markdownLimits.maximumTableRows, 100)
            let parsed = MarkdownDocumentParsing.parse(combined.text, limits: markdownLimits)
            let document = sanitizeImages(
                MarkdownRenderDocument(
                    blocks: parsed.blocks,
                    wasTruncated: parsed.wasTruncated || combined.wasTruncated
                ))
            rendered.append(SessionMarkdownTurn(id: turn.id, role: turn.role, document: document))
            remainingCharacters -= combined.text.count
        }

        if boundedMessages.count < transcript.messages.count || rendered.count < sourceTurns.count {
            wasTruncated = true
        }
        return SessionMarkdownTranscript(turns: rendered, wasTruncated: wasTruncated)
    }

    static func source(from transcript: SessionTranscript) -> String {
        groupedTurns(from: transcript.messages).map { turn in
            let role = turn.role == .user ? "User" : "Assistant"
            return "## \(role)\n\n\(turn.parts.joined(separator: "\n\n"))"
        }
        .joined(separator: "\n\n---\n\n")
    }

    static func sourceAsync(from transcript: SessionTranscript) async -> String? {
        let worker = Task.detached(priority: .userInitiated) { () -> String? in
            let turns = groupedTurns(from: transcript.messages)
            var sections: [String] = []
            sections.reserveCapacity(turns.count)
            for turn in turns {
                guard !Task.isCancelled else { return nil }
                let role = turn.role == .user ? "User" : "Assistant"
                sections.append("## \(role)\n\n\(turn.parts.joined(separator: "\n\n"))")
            }
            guard !Task.isCancelled else { return nil }
            return sections.joined(separator: "\n\n---\n\n")
        }
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private static func groupedTurns(from messages: [SessionMessage]) -> [SessionSourceTurn] {
        var turns: [SessionSourceTurn] = []
        turns.reserveCapacity(messages.count)
        for message in messages {
            if turns.last?.role == message.role {
                turns[turns.count - 1].parts.append(message.text)
            } else {
                turns.append(SessionSourceTurn(id: message.id, role: message.role, parts: [message.text]))
            }
        }
        return turns
    }

    private static func boundedText(
        from parts: [String],
        maximumCharacters: Int
    ) -> (text: String, wasTruncated: Bool) {
        let limit = max(0, maximumCharacters)
        var output = ""
        var characterCount = 0

        for part in parts {
            guard !Task.isCancelled else { return (output, true) }
            let separator = output.isEmpty ? "" : "\n\n"
            guard characterCount + separator.count < limit else {
                return (output, true)
            }
            output.append(separator)
            characterCount += separator.count

            let available = limit - characterCount
            let fragment = part.prefix(available)
            output.append(contentsOf: fragment)
            characterCount += fragment.count
            if fragment.count < part.count { return (output, true) }
        }
        return (output, false)
    }

    private static func sanitizeImages(_ document: MarkdownRenderDocument) -> MarkdownRenderDocument {
        MarkdownRenderDocument(
            blocks: document.blocks.map(sanitizeImage),
            wasTruncated: document.wasTruncated
        )
    }

    private static func sanitizeImage(_ block: MarkdownBlockModel) -> MarkdownBlockModel {
        let kind: MarkdownBlockModel.Kind
        switch block.kind {
        case .image(let image):
            let label = image.altText.isEmpty ? "Image omitted" : "Image: \(image.altText)"
            kind = .paragraph([MarkdownInlineRun(text: label, styles: [], destination: nil)])
        case .blockQuote(let blocks):
            kind = .blockQuote(blocks.map(sanitizeImage))
        case .unorderedList(let items):
            kind = .unorderedList(
                items.map {
                    MarkdownListItemModel(
                        checkbox: $0.checkbox,
                        taskOrdinal: $0.taskOrdinal,
                        blocks: $0.blocks.map(sanitizeImage)
                    )
                })
        case .orderedList(let start, let items):
            kind = .orderedList(
                start: start,
                items: items.map {
                    MarkdownListItemModel(
                        checkbox: $0.checkbox,
                        taskOrdinal: $0.taskOrdinal,
                        blocks: $0.blocks.map(sanitizeImage)
                    )
                })
        default:
            kind = block.kind
        }
        return MarkdownBlockModel(id: block.id, kind: kind)
    }
}
