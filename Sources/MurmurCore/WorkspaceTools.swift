import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A narrowly scoped, read-only view of a user-selected workspace.
actor WorkspaceTools {
    private let workspace: URL
    private let rootPath: String
    private let maximumFiles = 500
    private let maximumBytes = 1_000_000
    private let maximumResultBytes = 24_000
    private let maximumDepth = 12
    private var evidenceCache: [String: [Int: String]] = [:]

    init(workspace: URL) {
        self.workspace = workspace.standardizedFileURL
        self.rootPath = workspace.standardizedFileURL.path
    }

    nonisolated static var definitions: [JSONValue] {
        [
            schema("list_workspace_files", "List eligible workspace files. Optionally narrow by a relative directory.", ["directory": .object(["type": .array([.string("string"), .string("null")])])], ["directory"]),
            schema("search_workspace", "Search eligible workspace files by flexible terms and return bounded matching snippets with line numbers.", ["query": .object(["type": .string("string")]), "directory": .object(["type": .array([.string("string"), .string("null")])])], ["query", "directory"]),
            schema("read_workspace_file", "Read a bounded line range from an eligible workspace file.", ["path": .object(["type": .string("string")]), "line_start": .object(["type": .string("integer")]), "line_end": .object(["type": .string("integer")])], ["path", "line_start", "line_end"])
        ]
    }

    func execute(name: String, arguments: String) async throws -> String {
        guard let data = arguments.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ToolError.invalidArguments
        }
        switch name {
        case "list_workspace_files":
            let directory = object["directory"] as? String
            let files = try enumerate(directory: directory)
            return files.joined(separator: "\n")
        case "search_workspace":
            guard let query = object["query"] as? String, !query.trimmingCharacters(in: .whitespaces).isEmpty else { throw ToolError.invalidArguments }
            let paths = try enumerate(directory: object["directory"] as? String)
            let terms = Self.tokens(query)
            var output: [String] = []
            var used = 0
            for path in paths {
                try Task.checkCancellation()
                guard let body = try? read(path: path), body.utf8.count <= maximumBytes else { continue }
                let lines = body.components(separatedBy: .newlines)
                for (offset, line) in lines.enumerated() where !terms.isDisjoint(with: Self.tokens(line)) {
                    let item = "\(path):\(offset + 1): \(line)"
                    let bytes = item.utf8.count + 1
                    guard used + bytes <= maximumResultBytes else { return output.joined(separator: "\n") }
                    output.append(item); used += bytes
                    evidenceCache[path, default: [:]][offset + 1] = line
                    if output.count >= 30 { return output.joined(separator: "\n") }
                }
            }
            return output.joined(separator: "\n")
        case "read_workspace_file":
            guard let path = object["path"] as? String,
                  let start = object["line_start"] as? Int,
                  let end = object["line_end"] as? Int,
                  start > 0, end >= start, end - start < 200 else { throw ToolError.invalidArguments }
            let body = try read(path: path)
            let lines = body.components(separatedBy: .newlines)
            guard start <= lines.count else { throw ToolError.invalidPath }
            let upper = min(end, lines.count)
            var chunks: [String] = []
            for number in start...upper {
                let line = lines[number - 1]
                chunks.append("\(number): \(line)")
            }
            let result = chunks.joined(separator: "\n")
            guard result.utf8.count <= maximumResultBytes else { throw ToolError.resultTooLarge }
            for number in start...upper { evidenceCache[path, default: [:]][number] = lines[number - 1] }
            return result
        default: throw ToolError.unknownTool
        }
    }

    func validatedEvidence(_ evidence: [AgentEvidence]) async -> [AgentEvidence] {
        evidence.compactMap { item in
            guard let start = item.lineStart, start > 0,
                  let rows = evidenceCache[item.path] else { return nil }
            let end = item.lineEnd ?? start
            guard end >= start,
                  end - start < 200,
                  (start...end).allSatisfy({ rows[$0] != nil }) else { return nil }
            let exact = (start...end).compactMap { rows[$0] }.joined(separator: "\n")
            guard !item.excerpt.isEmpty, exact.contains(item.excerpt) else { return nil }
            return AgentEvidence(path: item.path, lineStart: start, lineEnd: end, excerpt: item.excerpt)
        }
    }

    private func read(path: String) throws -> String {
        let parts = try validatedParts(path)
        guard Self.supported(URL(fileURLWithPath: path)) else { throw ToolError.invalidPath }
        let rootFD = open(rootPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard rootFD >= 0 else { throw ToolError.invalidPath }
        defer { close(rootFD) }
        var current = rootFD
        var ownedFD: Int32 = -1
        for (index, part) in parts.enumerated() {
            let flags = O_RDONLY | O_NOFOLLOW | O_NONBLOCK | (index < parts.count - 1 ? O_DIRECTORY : 0)
            let next = openat(current, part, flags)
            if ownedFD >= 0 { close(ownedFD) }
            guard next >= 0 else { throw ToolError.invalidPath }
            ownedFD = next; current = next
        }
        defer { if ownedFD >= 0 { close(ownedFD) } }
        var info = stat()
        guard fstat(current, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size <= maximumBytes else { throw ToolError.invalidPath }
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
        let count = bytes.withUnsafeMutableBytes { ptr in systemRead(current, ptr.baseAddress, ptr.count) }
        guard count == bytes.count, let result = String(bytes: bytes, encoding: .utf8) else { throw ToolError.invalidPath }
        return result
    }

    private func validatedParts(_ path: String) throws -> [String] {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"),
              path.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { throw ToolError.invalidPath }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty, parts.count <= maximumDepth,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasPrefix(".") }),
              !parts.contains(where: { Self.ignoredDirectories.contains($0.lowercased()) }),
              !Self.isSecret(path),
              !isGitIgnored(path, isDirectory: false) else { throw ToolError.invalidPath }
        return parts
    }

    private func enumerate(directory: String?) throws -> [String] {
        let base: URL
        if let directory {
            _ = try validatedParts(directory)
            base = workspace.appendingPathComponent(directory, isDirectory: true)
            // Opening each component with O_NOFOLLOW also rejects symlinks.
            try verifyDirectory(directory)
        } else { base = workspace }
        var found: [String] = []
        var resultBytes = 0
        var visited = 0
        guard let enumerator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            visited += 1
            if visited > 20_000 { break }
            let relative = String(url.standardizedFileURL.path.dropFirst(rootPath.count + 1))
            let depth = relative.split(separator: "/").count
            if depth > maximumDepth {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { enumerator.skipDescendants() }
                continue
            }
            if relative.split(separator: "/").contains(where: { Self.ignoredDirectories.contains(String($0).lowercased()) }) || isGitIgnored(relative, isDirectory: (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true) {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { enumerator.skipDescendants() }
                continue
            }
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey]) else { continue }
            if Self.isSecret(relative) {
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            if values.isDirectory == true { continue }
            guard values.isRegularFile == true, Self.supported(url), (try? validatedParts(relative)) != nil,
                  (try? fileSize(path: relative)).map({ $0 <= maximumBytes }) == true else { continue }
            let itemBytes = relative.utf8.count + 1
            if resultBytes + itemBytes > maximumResultBytes - 20 { found.append("[truncated]"); break }
            found.append(relative); resultBytes += itemBytes
            if found.count >= maximumFiles { break }
        }
        return found.sorted()
    }

    private func verifyDirectory(_ path: String) throws {
        let parts = try validatedParts(path)
        let fd = open(rootPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw ToolError.invalidPath }
        var current = fd
        for part in parts {
            let next = openat(current, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            if current != fd { close(current) }
            guard next >= 0 else { close(fd); throw ToolError.invalidPath }
            current = next
        }
        if current != fd { close(current) }; close(fd)
    }

    private func fileSize(path: String) throws -> Int {
        let parts = try validatedParts(path)
        guard Self.supported(URL(fileURLWithPath: path)) else { throw ToolError.invalidPath }
        let fd = open(rootPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw ToolError.invalidPath }
        defer { close(fd) }
        var current = fd
        var owned: Int32 = -1
        for (index, part) in parts.enumerated() {
            let next = openat(current, part, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | (index < parts.count - 1 ? O_DIRECTORY : 0))
            if owned >= 0 { close(owned) }
            guard next >= 0 else { throw ToolError.invalidPath }
            owned = next; current = next
        }
        defer { if owned >= 0 { close(owned) } }
        var info = stat()
        guard fstat(current, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw ToolError.invalidPath }
        return Int(info.st_size)
    }

    private static let ignoredDirectories: Set<String> = [".build", ".git", ".gradle", ".next", ".swiftpm", ".turbo", ".venv", "build", "coverage", "deriveddata", "dist", "node_modules", "pods", "target", "vendor"]
    private static func supported(_ url: URL) -> Bool {
        let extensions: Set<String> = ["md", "markdown", "txt", "c", "cc", "cpp", "cs", "css", "dart", "ex", "exs", "fish", "go", "graphql", "gql", "h", "hpp", "html", "java", "js", "jsx", "kt", "kts", "lua", "m", "mm", "php", "proto", "py", "rb", "rs", "scss", "sh", "sql", "svelte", "swift", "ts", "tsx", "vue", "zsh", "conf", "config", "gradle", "ini", "json", "jsonc", "plist", "properties", "toml", "xml", "yaml", "yml"]
        let specials: Set<String> = ["brewfile", "cargo.lock", "cmakelists.txt", "containerfile", "dockerfile", "gemfile", "go.mod", "go.sum", "justfile", "makefile", "package.resolved", "package.swift", "podfile", "procfile", "pyproject.toml", "requirements.txt"]
        return extensions.contains(url.pathExtension.lowercased()) || specials.contains(url.lastPathComponent.lowercased())
    }
    private static func isSecret(_ path: String) -> Bool {
        path.split(separator: "/").contains { component in
            let value = String(component).lowercased()
            let url = URL(fileURLWithPath: value)
            let ext = url.pathExtension.lowercased()
            let base = url.deletingPathExtension().lastPathComponent.lowercased()
            return value == ".env" || value.hasPrefix(".env.") || [".npmrc", ".pypirc", "credentials", "credentials.json", "id_ed25519", "id_rsa", "secrets", "secrets.json"].contains(value) || ["key", "p12", "pem", "pfx"].contains(ext) || (["json", "jsonc", "toml", "yaml", "yml", "xml", "config", "conf", "ini", "plist", "properties"].contains(ext) && ["credentials", "secrets"].contains(base))
        }
    }
    private static func tokens(_ value: String) -> Set<String> { Set(value.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 1 }) }
    private static func schema(_ name: String, _ description: String, _ properties: [String: JSONValue], _ required: [String]) -> JSONValue {
        .object(["type": .string("function"), "name": .string(name), "description": .string(description), "parameters": .object(["type": .string("object"), "properties": .object(properties), "required": .array(required.map(JSONValue.string)), "additionalProperties": .bool(false)]), "strict": .bool(true)])
    }
    private func isGitIgnored(_ path: String, isDirectory: Bool) -> Bool {
        let parts = path.split(separator: "/").map(String.init)
        var rules: [IgnoreRule]
        do {
            rules = Self.parseIgnoreText(try Self.readIgnoreFile(root: rootPath, components: [".gitignore"]), base: "")
        } catch { return true }
        var baseComponents: [String] = []
        for part in parts.dropLast() {
            baseComponents.append(part)
            do {
                rules.append(contentsOf: Self.parseIgnoreText(
                    try Self.readIgnoreFile(root: rootPath, components: baseComponents + [".gitignore"]),
                    base: baseComponents.joined(separator: "/")
                ))
            } catch { return true }
        }
        var ignored = false
        if parts.count > 1 {
            for length in 1..<parts.count {
                let prefix = parts.prefix(length).joined(separator: "/")
                for rule in rules where rule.matches(prefix) { ignored = !rule.negated }
            }
        }
        for rule in rules where !rule.directoryOnly || isDirectory {
            if rule.matches(path) { ignored = !rule.negated }
        }
        return ignored
    }

    private static func readIgnoreFile(root: String, components: [String]) throws -> String? {
        guard !components.isEmpty, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") }) else { throw ToolError.invalidPath }
        let rootFD = open(root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard rootFD >= 0 else { throw ToolError.invalidPath }
        defer { close(rootFD) }
        var current = rootFD
        var owned: Int32 = -1
        for (index, component) in components.enumerated() {
            let next = openat(current, component, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | (index < components.count - 1 ? O_DIRECTORY : 0))
            let openError = errno
            if owned >= 0 { close(owned) }
            guard next >= 0 else {
                if openError == ENOENT { return nil }
                throw ToolError.invalidPath
            }
            owned = next; current = next
        }
        defer { if owned >= 0 { close(owned) } }
        var info = stat()
        guard fstat(current, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size >= 0, info.st_size <= 65_536 else { throw ToolError.invalidPath }
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
        let count = bytes.withUnsafeMutableBytes { systemRead(current, $0.baseAddress, $0.count) }
        guard count == bytes.count, let text = String(bytes: bytes, encoding: .utf8) else { throw ToolError.invalidPath }
        return text
    }
    private static func parseIgnoreText(_ text: String?, base: String) -> [IgnoreRule] {
        guard let text else { return [] }
        return text.components(separatedBy: .newlines).compactMap { raw in
            var pattern = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            // Git ignores unescaped trailing spaces; leading/escaped spaces are literal.
            while pattern.hasSuffix(" ") {
                let slashes = pattern.dropLast().reversed().prefix(while: { $0 == "\\" }).count
                if slashes % 2 == 1 { break }
                pattern.removeLast()
            }
            guard !pattern.isEmpty, !pattern.hasPrefix("#") else { return nil }
            let negated = pattern.hasPrefix("!"); if negated { pattern.removeFirst() }
            let dir = pattern.hasSuffix("/"); if dir { pattern.removeLast() }
            let anchored = pattern.hasPrefix("/"); if anchored { pattern.removeFirst() }
            return IgnoreRule(pattern: pattern, base: base, negated: negated, directoryOnly: dir, anchored: anchored)
        }
    }

    private struct IgnoreRule {
        let pattern: String; let base: String; let negated: Bool; let directoryOnly: Bool; let anchored: Bool
        func matches(_ path: String) -> Bool {
            let path = path.lowercased()
            let base = base.lowercased()
            let relative = base.isEmpty ? path : String(path.dropFirst(min(path.count, base.count + 1)))
            guard base.isEmpty || path == base || path.hasPrefix(base + "/") else { return false }
            let chunks = relative.split(separator: "/").map(String.init)
            let value: String
            if !pattern.contains("/") && !anchored { value = chunks.first(where: { Self.wildcard(pattern, $0) }) ?? "" }
            else { value = relative }
            let matched = !value.isEmpty && Self.wildcard(pattern, value)
            // Negation is deliberately ignored: an ignored parent can never be reopened.
            return matched && !negated
        }
        private static func wildcard(_ pattern: String, _ value: String) -> Bool {
            let patterns = pattern.lowercased().split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            let components = value.lowercased().split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            // Fail closed for pathological policy patterns rather than spending unbounded work.
            guard patterns.count <= 64, pattern.utf8.count <= 2_048 else { return true }
            var positions: Set<Int> = [0]
            for componentPattern in patterns {
                if componentPattern == "**" {
                    if let first = positions.min() { positions = Set(first...components.count) }
                } else {
                    positions = Set(positions.compactMap { index in
                        guard index < components.count,
                              fnmatch(componentPattern, components[index], FNM_PATHNAME) == 0 else { return nil }
                        return index + 1
                    })
                }
                if positions.isEmpty { return false }
            }
            return positions.contains(components.count)
        }
    }
    private enum ToolError: Error { case invalidArguments, invalidPath, unknownTool, resultTooLarge }
}

/// Thin wrapper so call sites are not shadowed by same-named members and work on both libcs.
private func systemRead(_ fd: Int32, _ buffer: UnsafeMutableRawPointer?, _ count: Int) -> Int {
    #if canImport(Darwin)
    return Darwin.read(fd, buffer, count)
    #else
    return Glibc.read(fd, buffer, count)
    #endif
}
