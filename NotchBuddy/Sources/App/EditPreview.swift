import Foundation
import SwiftUI

// MARK: - Live edit preview (file being edited by the agent, shown in the .editing view)

struct DiffLine: Identifiable, Equatable {
    enum Kind { case context, removed, added }
    let id: Int
    let number: Int?
    let text: String
    let kind: Kind
}

struct EditPreview: Identifiable, Equatable {
    let id = UUID()
    let filePath: String
    let displayPath: String
    let lines: [DiffLine]
    let jumpLine: Int?

    var fileName: String { URL(fileURLWithPath: filePath).lastPathComponent }
    var fileExtension: String { URL(fileURLWithPath: filePath).pathExtension.lowercased() }
}

// MARK: - Builder: hook tool_input → a few diff rows with real line numbers

enum EditPreviewBuilder {
    static let maxRows = 7

    /// Handles Claude Code (Edit/MultiEdit/Write), Copilot SDK (Edit/Write with path/old_str/new_str/file_text)
    /// and VS Code's Local harness (replace_string_in_file, multi_replace_string_in_file, create_file,
    /// insert_edit_into_file, apply_patch). Called on PreToolUse, so the file on disk is still the old one.
    static func build(tool: String, input: [String: Any], cwd: String) -> EditPreview? {
        var path = string(input, "file_path", "path", "filePath")
        var old: String?
        var new: String?

        if let o = string(input, "old_string", "old_str", "oldString"),
           let n = string(input, "new_string", "new_str", "newString") {
            old = o; new = n
        } else if let edit = (input["edits"] as? [[String: Any]] ?? input["replacements"] as? [[String: Any]])?.first,
                  let o = string(edit, "old_string", "old_str", "oldString"),
                  let n = string(edit, "new_string", "new_str", "newString") {
            old = o; new = n
            path = path ?? string(edit, "file_path", "path", "filePath")
        } else if let patch = string(input, "input", "patch"), let parsed = parsePatch(patch) {
            path = path ?? parsed.path
            old = parsed.old; new = parsed.new
        } else if let content = string(input, "content", "file_text", "code") {
            new = content
        }

        guard let path, !path.isEmpty, let new else { return nil }
        let absolute = path.hasPrefix("/") ? path : (cwd as NSString).appendingPathComponent(path)
        let fileLines = readLines(absolute)

        let rows: [DiffLine]
        let jump: Int?
        if let old, !old.isEmpty {
            (rows, jump) = replacementRows(old: old, new: new, fileLines: fileLines)
        } else {
            // New file (or full rewrite): the first lines of the content, all added
            let added = lines(new).prefix(maxRows)
            rows = added.enumerated().map { DiffLine(id: $0.offset, number: $0.offset + 1, text: $0.element, kind: .added) }
            jump = 1
        }
        guard !rows.isEmpty else { return nil }

        var display = absolute
        if !cwd.isEmpty, absolute.hasPrefix(cwd + "/") { display = String(absolute.dropFirst(cwd.count + 1)) }
        return EditPreview(filePath: absolute, displayPath: display, lines: rows, jumpLine: jump)
    }

    private static func replacementRows(old: String, new: String, fileLines: [String]?) -> ([DiffLine], Int?) {
        let o = lines(old), n = lines(new)
        // Unchanged lines at both ends of old/new are context, not changes
        var pre = 0
        while pre < o.count, pre < n.count, o[pre] == n[pre] { pre += 1 }
        var suf = 0
        while suf < o.count - pre, suf < n.count - pre, o[o.count - 1 - suf] == n[n.count - 1 - suf] { suf += 1 }
        let removed = Array(o[pre..<(o.count - suf)])
        let added = Array(n[pre..<(n.count - suf)])

        // Where the change starts in the file (1-based), if old text is found on disk
        var firstLine: Int?
        var lead = ""
        if let fileLines, let start = find(o, in: fileLines) {
            firstLine = start + pre + 1
            // old_string may begin mid-line (usually after indentation): keep that prefix on screen
            if pre == 0, fileLines[start].hasSuffix(o[0]) {
                lead = String(fileLines[start].dropLast(o[0].count))
            }
        }

        let r = min(removed.count, added.isEmpty ? maxRows - 2 : 2)
        let a = min(added.count, max(1, maxRows - r - 1))
        let left = max(0, maxRows - r - a)

        var before: [(Int?, String)] = []
        var after: [(Int?, String)] = []
        if let firstLine, let fileLines {
            let bStart = max(0, firstLine - 1 - min(2, left))
            for i in bStart..<(firstLine - 1) { before.append((i + 1, fileLines[i])) }
            let oldEnd = firstLine - 1 + removed.count          // index after the removed block (old file)
            let room = left - before.count
            for k in 0..<room where oldEnd + k < fileLines.count {
                after.append((firstLine + added.count + k, fileLines[oldEnd + k]))
            }
        } else {
            before = o[..<pre].suffix(min(2, left)).map { (nil, $0) }
            after = o[(o.count - suf)...].prefix(left - before.count).map { (nil, $0) }
        }

        var rows: [DiffLine] = []
        func add(_ number: Int?, _ text: String, _ kind: DiffLine.Kind) {
            rows.append(DiffLine(id: rows.count, number: number, text: text, kind: kind))
        }
        before.forEach { add($0.0, $0.1, .context) }
        for (i, line) in removed.prefix(r).enumerated() {
            add(firstLine.map { $0 + i }, i == 0 ? lead + line : line, .removed)
        }
        for (i, line) in added.prefix(a).enumerated() {
            add(firstLine.map { $0 + i }, i == 0 ? lead + line : line, .added)
        }
        after.forEach { add($0.0, $0.1, .context) }
        return (rows, firstLine)
    }

    /// Parses the first hunk of an apply_patch body ("*** Update File: …", "@@", " ", "-", "+").
    private static func parsePatch(_ patch: String) -> (path: String?, old: String?, new: String)? {
        var path: String?
        var old: [String] = [], new: [String] = []
        var inHunk = false, isAdd = false
        for line in lines(patch) {
            if line.hasPrefix("*** Update File: ") || line.hasPrefix("*** Add File: ") {
                if path != nil { break }
                isAdd = line.hasPrefix("*** Add File: ")
                path = String(line.split(separator: ":", maxSplits: 1)[1]).trimmingCharacters(in: .whitespaces)
                inHunk = isAdd
            } else if line.hasPrefix("@@") {
                if !old.isEmpty || !new.isEmpty { break }
                inHunk = true
            } else if line.hasPrefix("***") {
                if !old.isEmpty || !new.isEmpty { break }
            } else if inHunk {
                if line.hasPrefix("+") { new.append(String(line.dropFirst())) }
                else if line.hasPrefix("-") { old.append(String(line.dropFirst())) }
                else { let t = line.hasPrefix(" ") ? String(line.dropFirst()) : line; old.append(t); new.append(t) }
            }
        }
        guard path != nil, !new.isEmpty || !old.isEmpty else { return nil }
        return (path, isAdd ? nil : old.joined(separator: "\n"), new.joined(separator: "\n"))
    }

    private static func find(_ needle: [String], in hay: [String]) -> Int? {
        guard !needle.isEmpty, needle.count <= hay.count else { return nil }
        // old_string may start and end mid-line: its first line is a suffix, its last line a prefix
        for start in 0...(hay.count - needle.count) {
            var ok = true
            for k in 0..<needle.count {
                let h = hay[start + k], n = needle[k]
                let match = needle.count == 1 ? h.contains(n)
                    : k == 0 ? h.hasSuffix(n)
                    : k == needle.count - 1 ? h.hasPrefix(n)
                    : h == n
                if !match { ok = false; break }
            }
            if ok { return start }
        }
        return nil
    }

    private static func readLines(_ path: String) -> [String]? {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int,
              size <= 2_000_000,
              let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return lines(text)
    }

    private static func lines(_ text: String) -> [String] {
        var out = text.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.replacingOccurrences(of: "\t", with: "    ") }
        // A final newline is not a line of its own
        if out.count > 1, out.last == "" { out.removeLast() }
        return out
    }

    private static func string(_ dict: [String: Any], _ keys: String...) -> String? {
        for key in keys { if let v = dict[key] as? String { return v } }
        return nil
    }
}

// MARK: - Tiny syntax highlighter (keywords, types, calls, constants, strings, numbers, comments)

enum CodeHighlighter {
    static let plain    = Color(hex: "#C9CDD4")
    static let keyword  = Color(hex: "#EEF0F3")
    static let type     = Color(hex: "#F2C774")
    static let call     = Color(hex: "#F2C774")
    static let constant = Color(hex: "#F5956C")
    static let string   = Color(hex: "#B8D98A")
    static let number   = Color(hex: "#F5956C")
    static let comment  = Color(hex: "#5E6570")

    private static let keywords: Set<String> = [
        "import", "from", "export", "default", "const", "let", "var", "function", "return", "if", "else",
        "for", "while", "in", "of", "new", "class", "struct", "enum", "extension", "protocol", "func",
        "private", "public", "static", "final", "async", "await", "try", "catch", "throw", "throws",
        "guard", "switch", "case", "break", "continue", "true", "false", "nil", "null", "undefined",
        "self", "this", "def", "lambda", "type", "interface", "extends", "implements", "package", "fn",
        "pub", "mut", "impl", "use", "void", "final", "late", "required", "override", "some", "any",
    ]

    nonisolated(unsafe) private static let rules: [(NSRegularExpression, (String) -> Color?)] = {
        func re(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p) }
        return [
            (re(#"\b[A-Za-z_][A-Za-z0-9_]*\b"#), { word in
                if keywords.contains(word) { return keyword }
                if word.count > 1, word == word.uppercased(), word.contains(where: \.isLetter) { return constant }
                if word.first?.isUppercase == true { return type }
                return nil
            }),
            (re(#"\b[A-Za-z_][A-Za-z0-9_]*(?=\s*\()"#), { _ in call }),
            (re(#"\b\d+(\.\d+)?\b"#), { _ in number }),
            (re(#""(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|`[^`]*`"#), { _ in string }),
            (re(#"(//|#(?!\w)|--\s).*$"#), { _ in comment }),
        ]
    }()

    static func highlight(_ line: String) -> AttributedString {
        var attr = AttributedString(line)
        attr.foregroundColor = plain
        let ns = line as NSString
        for (regex, color) in rules {
            for m in regex.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
                guard let c = color(ns.substring(with: m.range)),
                      let r = Range(m.range, in: line),
                      let ar = Range(r, in: attr) else { continue }
                attr[ar].foregroundColor = c
            }
        }
        return attr
    }
}
