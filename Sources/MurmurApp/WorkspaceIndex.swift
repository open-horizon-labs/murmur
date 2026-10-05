import Foundation

struct WorkspaceIndex: Sendable {
    private let documents: [WorkspaceDocument]
    private let tokenizedDocuments: [String: Set<String>]

    init(documents: [WorkspaceDocument]) {
        self.documents = documents
        self.tokenizedDocuments = Dictionary(
            uniqueKeysWithValues: documents.map { document in
                (document.id, Self.tokens(in: "\(document.title) \(document.source) \(document.body)"))
            }
        )
    }

    // A source file can produce several searchable chunks, but this remains a
    // user-facing file count for compatibility with the workspace picker.
    var documentCount: Int {
        Set(documents.map { $0.url.standardizedFileURL.path }).count
    }

    func search(_ query: String, limit: Int = 3) -> [Cue] {
        let queryTokens = Self.tokens(in: query)
        guard !queryTokens.isEmpty else { return [] }

        return documents
            .compactMap { document -> Cue? in
                guard let documentTokens = tokenizedDocuments[document.id] else { return nil }
                let overlap = queryTokens.intersection(documentTokens)
                guard !overlap.isEmpty else { return nil }

                let titleTokens = Self.tokens(in: document.title)
                let pathTokens = Self.tokens(in: document.source)
                let titleMatches = queryTokens.intersection(titleTokens).count
                let pathMatches = queryTokens.intersection(pathTokens).count
                guard overlap.count >= 2 || titleMatches >= 1 || pathMatches >= 1 else { return nil }
                let freshness = max(0, 1 - Date().timeIntervalSince(document.updatedAt) / (365 * 86_400))
                let compactQuery = Self.compactIdentifier(query)
                let compactTitle = Self.compactIdentifier(document.title)
                let exactIdentifierBonus = compactQuery.count > 2 && compactTitle.contains(compactQuery) ? 3.0 : 0
                let score = Double(overlap.count)
                    + Double(titleMatches) * 2.25
                    + Double(pathMatches) * 1.25
                    + exactIdentifierBonus
                    + freshness * 0.2

                return Cue(
                    id: document.id,
                    title: document.title,
                    detail: Self.bestSentence(in: document.body, matching: queryTokens),
                    source: document.source,
                    url: document.url,
                    relevance: score,
                    tier: .fast
                )
            }
            .sorted { lhs, rhs in
                if lhs.relevance == rhs.relevance { return lhs.title < rhs.title }
                return lhs.relevance > rhs.relevance
            }
            .prefix(limit)
            .map { $0 }
    }

    private static func tokens(in text: String) -> Set<String> {
        let stopwords: Set<String> = [
            "a", "an", "and", "are", "at", "be", "but", "by", "for", "from", "i",
            "in", "is", "it", "of", "on", "or", "our", "that", "the", "this", "to",
            "we", "what", "when", "with", "you"
        ]

        let identifierAwareText = text
            .replacingOccurrences(
                of: "([a-z0-9])([A-Z])",
                with: "$1 $2",
                options: .regularExpression
            )
            .replacingOccurrences(of: "_", with: " ")

        return Set(
            identifierAwareText.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count > 1 && !stopwords.contains($0) }
        )
    }

    private static func compactIdentifier(_ text: String) -> String {
        text.lowercased().filter(\.isLetter)
    }

    private static func bestSentence(in body: String, matching queryTokens: Set<String>) -> String {
        let lines = body.components(separatedBy: .newlines)
        if lines.count > 1 {
            let bestLineIndex = lines.indices.max { lhs, rhs in
                tokens(in: lines[lhs]).intersection(queryTokens).count
                    < tokens(in: lines[rhs]).intersection(queryTokens).count
            } ?? lines.startIndex
            let lower = max(lines.startIndex, bestLineIndex - 1)
            let upper = min(lines.index(before: lines.endIndex), bestLineIndex + 1)
            let excerpt = lines[lower...upper]
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !excerpt.isEmpty { return excerpt }
        }

        let sentences = body.split(whereSeparator: { ".!?".contains($0) }).map(String.init)
        return sentences.max { lhs, rhs in
            tokens(in: lhs).intersection(queryTokens).count < tokens(in: rhs).intersection(queryTokens).count
        }?.trimmingCharacters(in: .whitespacesAndNewlines) ?? body
    }
}

struct LoadedWorkspace: Sendable {
    let name: String
    let index: WorkspaceIndex
}

actor WorkspaceLoader {
    private let documentExtensions: Set<String> = ["md", "markdown", "txt"]
    private let sourceExtensions: Set<String> = [
        "c", "cc", "cpp", "cs", "css", "dart", "ex", "exs", "fish", "go", "graphql",
        "gql", "h", "hpp", "html", "java", "js", "jsx", "kt", "kts", "lua", "m",
        "mm", "php", "proto", "py", "rb", "rs", "scss", "sh", "sql", "svelte",
        "swift", "ts", "tsx", "vue", "zsh"
    ]
    private let configExtensions: Set<String> = [
        "conf", "config", "gradle", "ini", "json", "jsonc", "plist", "properties",
        "toml", "xml", "yaml", "yml"
    ]
    private let specialFilenames: Set<String> = [
        "brewfile", "cargo.lock", "cmakelists.txt", "containerfile", "dockerfile", "gemfile",
        "go.mod", "go.sum", "justfile", "makefile", "package.resolved", "package.swift",
        "podfile", "procfile", "pyproject.toml", "requirements.txt"
    ]
    private let ignoredDirectories: Set<String> = [
        ".build", ".git", ".gradle", ".next", ".swiftpm", ".turbo", ".venv", "build",
        "coverage", "deriveddata", "dist", "node_modules", "pods", "target", "vendor"
    ]
    private let secretFilenames: Set<String> = [
        ".npmrc", ".pypirc", "credentials", "credentials.json", "id_ed25519", "id_rsa",
        "secrets", "secrets.json"
    ]
    private let secretExtensions: Set<String> = ["key", "p12", "pem", "pfx"]
    private let maximumFileSize = 1_000_000
    private let maximumDocumentCount = 2_000
    private let chunkLineCount = 120
    private let chunkLineOverlap = 20

    func load(folder: URL) throws -> LoadedWorkspace {
        let hasScopedAccess = folder.startAccessingSecurityScopedResource()
        defer {
            if hasScopedAccess { folder.stopAccessingSecurityScopedResource() }
        }

        let keys: [URLResourceKey] = [
            .isRegularFileKey, .isDirectoryKey, .isHiddenKey,
            .fileSizeKey, .contentModificationDateKey
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw WorkspaceLoadingError.cannotReadFolder
        }

        let gitignore = GitIgnoreRules(folder: folder)
        var documents: [WorkspaceDocument] = []
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: Set(keys))
            let relativePath = relativePath(of: fileURL, under: folder)
            if values?.isDirectory == true {
                if shouldIgnoreDirectory(fileURL)
                    || gitignore.ignores(relativePath: relativePath, isDirectory: true) {
                    enumerator.skipDescendants()
                }
                continue
            }

            guard values?.isRegularFile == true,
                  isSupported(fileURL),
                  !isSecretBearing(fileURL),
                  !gitignore.ignores(relativePath: relativePath, isDirectory: false),
                  (values?.fileSize ?? maximumFileSize + 1) <= maximumFileSize,
                  let body = try? String(contentsOf: fileURL, encoding: .utf8),
                  !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }

            let remainingCapacity = maximumDocumentCount - documents.count
            documents.append(contentsOf: chunks(
                for: fileURL,
                relativePath: relativePath,
                body: body,
                updatedAt: values?.contentModificationDate ?? .distantPast
            ).prefix(remainingCapacity))

            if documents.count >= maximumDocumentCount { break }
        }

        guard !documents.isEmpty else { throw WorkspaceLoadingError.noSupportedDocuments }
        return LoadedWorkspace(name: folder.lastPathComponent, index: WorkspaceIndex(documents: documents))
    }

    private func isSupported(_ url: URL) -> Bool {
        let filename = url.lastPathComponent.lowercased()
        let fileExtension = url.pathExtension.lowercased()
        return specialFilenames.contains(filename)
            || documentExtensions.contains(fileExtension)
            || sourceExtensions.contains(fileExtension)
            || configExtensions.contains(fileExtension)
    }

    private func isSecretBearing(_ url: URL) -> Bool {
        let filename = url.lastPathComponent.lowercased()
        let basename = url.deletingPathExtension().lastPathComponent.lowercased()
        let isSensitiveConfig = configExtensions.contains(url.pathExtension.lowercased())
            && ["credentials", "secrets"].contains(basename)
        return filename == ".env"
            || filename.hasPrefix(".env.")
            || secretFilenames.contains(filename)
            || secretExtensions.contains(url.pathExtension.lowercased())
            || isSensitiveConfig
    }

    private func shouldIgnoreDirectory(_ url: URL) -> Bool {
        ignoredDirectories.contains(url.lastPathComponent.lowercased())
    }

    private func relativePath(of url: URL, under folder: URL) -> String {
        String(url.standardizedFileURL.path.dropFirst(folder.standardizedFileURL.path.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func chunks(
        for fileURL: URL,
        relativePath: String,
        body: String,
        updatedAt: Date
    ) -> [WorkspaceDocument] {
        let lines = body.components(separatedBy: .newlines)
        let isDocument = documentExtensions.contains(fileURL.pathExtension.lowercased())
        let title = isDocument
            ? fileURL.deletingPathExtension().lastPathComponent
            : fileURL.lastPathComponent
        let shouldChunk = !isDocument && lines.count > chunkLineCount
        let ranges: [ClosedRange<Int>]
        if shouldChunk {
            let stride = chunkLineCount - chunkLineOverlap
            ranges = Swift.stride(from: 0, to: lines.count, by: stride).map { start in
                start...min(start + chunkLineCount - 1, lines.count - 1)
            }
        } else {
            ranges = [0...max(0, lines.count - 1)]
        }

        return ranges.map { range in
            let lineSuffix = isDocument ? "" : ":\(range.lowerBound + 1)-\(range.upperBound + 1)"
            return WorkspaceDocument(
                id: shouldChunk
                    ? "\(fileURL.standardizedFileURL.path)#L\(range.lowerBound + 1)-L\(range.upperBound + 1)"
                    : fileURL.standardizedFileURL.path,
                title: title,
                source: relativePath + lineSuffix,
                body: lines[range].joined(separator: "\n"),
                url: fileURL,
                updatedAt: updatedAt
            )
        }
    }
}

private struct GitIgnoreRules: Sendable {
    private struct Rule: Sendable {
        let pattern: String
        let isNegated: Bool
        let isDirectoryOnly: Bool
        let isAnchored: Bool
    }

    private let rules: [Rule]

    init(folder: URL) {
        let url = folder.appendingPathComponent(".gitignore")
        let contents = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        self.rules = contents.components(separatedBy: .newlines).compactMap { rawLine in
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
            let isNegated = line.hasPrefix("!")
            if isNegated { line.removeFirst() }
            let isDirectoryOnly = line.hasSuffix("/")
            if isDirectoryOnly { line.removeLast() }
            let isAnchored = line.hasPrefix("/")
            if isAnchored { line.removeFirst() }
            guard !line.isEmpty else { return nil }
            return Rule(
                pattern: line,
                isNegated: isNegated,
                isDirectoryOnly: isDirectoryOnly,
                isAnchored: isAnchored
            )
        }
    }

    func ignores(relativePath: String, isDirectory: Bool) -> Bool {
        var ignored = false
        for rule in rules where !rule.isDirectoryOnly || isDirectory {
            if matches(rule: rule, relativePath: relativePath) {
                ignored = !rule.isNegated
            }
        }
        return ignored
    }

    private func matches(rule: Rule, relativePath: String) -> Bool {
        let path = relativePath.replacingOccurrences(of: "\\", with: "/")
        if !rule.pattern.contains("/") && !rule.isAnchored {
            return path.split(separator: "/").contains { wildcard(rule.pattern, matches: String($0)) }
        }
        return wildcard(rule.pattern, matches: path)
            || (!rule.isAnchored && wildcard("*/\(rule.pattern)", matches: path))
    }

    private func wildcard(_ pattern: String, matches value: String) -> Bool {
        var expression = NSRegularExpression.escapedPattern(for: pattern)
        expression = expression.replacingOccurrences(of: "\\*\\*", with: ".*")
        expression = expression.replacingOccurrences(of: "\\*", with: "[^/]*")
        expression = expression.replacingOccurrences(of: "\\?", with: "[^/]")
        return value.range(of: "^\(expression)$", options: .regularExpression) != nil
    }
}

enum WorkspaceLoadingError: LocalizedError {
    case cannotReadFolder
    case noSupportedDocuments

    var errorDescription: String? {
        switch self {
        case .cannotReadFolder:
            "Murmur could not read that folder."
        case .noSupportedDocuments:
            "No readable documents, source files, or project manifests were found in that folder."
        }
    }
}

enum DemoWorkspace {
    static let index = WorkspaceIndex(documents: [
        WorkspaceDocument(
            id: "decision-sso",
            title: "Acme SSO exception",
            source: "Decisions / 14 Aug",
            body: "We approved a temporary SSO exception for Acme through September 30. Security review is required before renewal and Mira owns the follow-up.",
            url: URL(string: "https://example.com/workspace/decisions/acme-sso")!,
            updatedAt: .now.addingTimeInterval(-14 * 86_400)
        ),
        WorkspaceDocument(
            id: "issue-482",
            title: "ACME-482 · SAML role mapping",
            source: "Linear / In progress",
            body: "The remaining blocker is group-to-role mapping for Acme's EU tenant. The fix is in review and is expected before Friday.",
            url: URL(string: "https://example.com/workspace/issues/ACME-482")!,
            updatedAt: .now.addingTimeInterval(-2 * 86_400)
        ),
        WorkspaceDocument(
            id: "account-acme",
            title: "Acme renewal brief",
            source: "Accounts / Acme",
            body: "Acme renews October 15 at 120 seats. Their priorities are SSO reliability, EU data residency, and a clear migration date. Last call sentiment was positive but conditional on the SAML fix.",
            url: URL(string: "https://example.com/workspace/accounts/acme")!,
            updatedAt: .now.addingTimeInterval(-5 * 86_400)
        ),
        WorkspaceDocument(
            id: "eu-residency",
            title: "EU data residency rollout",
            source: "Docs / Launch plan",
            body: "The EU region enters limited availability on October 1. Existing customers can request migration after the two-week validation window.",
            url: URL(string: "https://example.com/workspace/docs/eu-residency")!,
            updatedAt: .now.addingTimeInterval(-8 * 86_400)
        ),
        WorkspaceDocument(
            id: "pricing-enterprise",
            title: "Enterprise pricing guardrails",
            source: "Sales / Pricing",
            body: "Discounts above twelve percent require finance approval. Multi-year renewals may include the EU migration service at no charge.",
            url: URL(string: "https://example.com/workspace/sales/pricing")!,
            updatedAt: .now.addingTimeInterval(-30 * 86_400)
        )
    ])
}
