import Foundation

/// An AI agent client that stores Agent Skills (`<name>/SKILL.md`) on disk.
/// The registry of where each one keeps its skills — the basis for scanning a
/// scattered skill landscape into one catalog.
enum SkillAgent: String, CaseIterable, Identifiable, Sendable {
    case claude
    case codex
    case traeCN

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .traeCN: "Trae CN"
        }
    }

    /// Directories to scan, relative to the user's home. `readOnly` marks
    /// vendor/builtin skill sets that must not be edited or deleted;
    /// `recursive` finds SKILL.md at any depth (for nested plugin layouts).
    var scanDirectories: [SkillScanDirectory] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch self {
        case .claude:
            // Claude Code / Claude CLI share one personal skills dir. (Claude
            // Desktop's per-session plugin caches are ephemeral and not
            // user-managed, so they're intentionally not scanned.)
            return [SkillScanDirectory(url: home.appendingPathComponent(".claude/skills"), isReadOnly: false)]
        case .codex:
            // Codex user skills. `.system/` internals and `vendor_imports` are
            // not the user's to manage, so only the top-level skills dir is
            // scanned (its `.system` subdir has no top-level SKILL.md).
            return [SkillScanDirectory(url: home.appendingPathComponent(".codex/skills"), isReadOnly: false)]
        case .traeCN:
            return [
                SkillScanDirectory(url: home.appendingPathComponent(".trae-cn/skills"), isReadOnly: false),
                SkillScanDirectory(
                    url: home.appendingPathComponent(".trae-cn/builtin_skills"), isReadOnly: true),
            ]
        }
    }
}

struct SkillScanDirectory: Sendable, Equatable {
    let url: URL
    let isReadOnly: Bool
    var isRecursive: Bool = false
}

/// One on-disk copy of a skill, under a specific agent.
struct SkillInstallation: Identifiable, Equatable, Sendable {
    let agent: SkillAgent
    /// The skill's folder (containing SKILL.md).
    let url: URL
    let isReadOnly: Bool
    /// Stable content hash of SKILL.md, for drift detection across copies.
    let contentHash: String
    /// True when this location is a symlink (into the canonical library) rather
    /// than an independent copy.
    let isSymlink: Bool

    var id: String { url.path }
}

/// A logical skill, aggregated across every agent it's installed in.
struct SkillEntry: Identifiable, Equatable, Sendable {
    let name: String
    let description: String
    let version: String?
    let license: String?
    let installations: [SkillInstallation]

    var id: String { name }

    /// Distinct agents this skill is active in, in registry order.
    var agents: [SkillAgent] {
        var seen = Set<SkillAgent>()
        return installations.compactMap { seen.insert($0.agent).inserted ? $0.agent : nil }
    }

    /// True when copies disagree on content — the silent "edited one, others
    /// stale" trap.
    var hasDrift: Bool {
        Set(installations.map(\.contentHash)).count > 1
    }

    /// True when every writable copy is a symlink — i.e. fully consolidated
    /// into the canonical library (single source of truth, no drift possible).
    var isConsolidated: Bool {
        let writable = installations.filter { !$0.isReadOnly }
        return !writable.isEmpty && writable.allSatisfy(\.isSymlink)
    }
}

/// Pure parsing/aggregation for skills, split from the filesystem scan so it's
/// unit-testable.
enum SkillCatalog {
    struct Metadata: Equatable {
        var name: String?
        var description: String?
        var version: String?
        var license: String?
    }

    /// Extracts the leading `---` YAML frontmatter of a SKILL.md into scalar
    /// key/values. Tolerant and shallow: every `key: value` line inside the
    /// block is recorded (last wins), nested keys included, quotes stripped.
    static func parseFrontmatter(_ content: String) -> [String: String] {
        let lines = content.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return [:] }

        var result: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.trimmingCharacters(in: .whitespaces) == "---" { break }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else {
                continue
            }
            var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if value.count >= 2,
                (value.hasPrefix("\"") && value.hasSuffix("\""))
                    || (value.hasPrefix("'") && value.hasSuffix("'"))
            {
                value = String(value.dropFirst().dropLast())
            }
            if !value.isEmpty { result[key] = value }
        }
        return result
    }

    static func metadata(from content: String) -> Metadata {
        let fm = parseFrontmatter(content)
        return Metadata(
            name: fm["name"], description: fm["description"], version: fm["version"], license: fm["license"])
    }

    /// A single discovered SKILL.md before aggregation.
    struct RawSkill: Equatable {
        let agent: SkillAgent
        let url: URL
        let isReadOnly: Bool
        let contentHash: String
        let metadata: Metadata
        var isSymlink: Bool = false
    }

    /// Groups raw discoveries into one entry per skill name (frontmatter `name`,
    /// falling back to the folder name), sorted by name. The aggregated
    /// description/version come from the first installation that has them.
    static func aggregate(_ raws: [RawSkill]) -> [SkillEntry] {
        var byName: [String: [RawSkill]] = [:]
        var order: [String] = []
        for raw in raws {
            let name = raw.metadata.name ?? raw.url.lastPathComponent
            if byName[name] == nil { order.append(name) }
            byName[name, default: []].append(raw)
        }

        return order.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }.map { name in
            let group = byName[name]!
            return SkillEntry(
                name: name,
                description: group.compactMap { $0.metadata.description }.first ?? "",
                version: group.compactMap { $0.metadata.version }.first,
                license: group.compactMap { $0.metadata.license }.first,
                installations: group.map {
                    SkillInstallation(
                        agent: $0.agent, url: $0.url, isReadOnly: $0.isReadOnly, contentHash: $0.contentHash,
                        isSymlink: $0.isSymlink)
                }
            )
        }
    }

    /// Stable FNV-1a 64-bit hash (hex) of a string — for cross-copy drift
    /// detection without a crypto dependency or storing full contents.
    static func stableHash(_ string: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }
}
