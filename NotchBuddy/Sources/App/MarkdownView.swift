import SwiftUI

// MARK: - Block model

enum MarkdownBlock: Equatable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case code(language: String?, text: String)
    case bullet(indent: Int, marker: String, text: String)
    case quote(String)
    case table(rows: [[String]])
    case rule
}

enum MarkdownParser {
    static func parse(_ source: String) -> [MarkdownBlock] {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var i = 0

        func flushParagraph() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: "\n")))
                paragraph.removeAll()
            }
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph()
                let fence = String(trimmed.prefix(3))
                let lang = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                i += 1
                // An unterminated fence (e.g. truncated reply) runs to the end.
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[i])
                    i += 1
                }
                blocks.append(.code(language: lang.isEmpty ? nil : lang, text: code.joined(separator: "\n")))
                i += 1
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                i += 1
                continue
            }

            if isRule(trimmed) {
                flushParagraph()
                blocks.append(.rule)
                i += 1
                continue
            }

            if let h = heading(trimmed) {
                flushParagraph()
                blocks.append(.heading(level: h.0, text: h.1))
                i += 1
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                var quoted: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard t.hasPrefix(">") else { break }
                    quoted.append(String(t.dropFirst()).trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                blocks.append(.quote(quoted.joined(separator: "\n")))
                continue
            }

            if trimmed.hasPrefix("|"), i + 1 < lines.count, isTableSeparator(lines[i + 1]) {
                flushParagraph()
                var rows: [[String]] = [cells(trimmed)]
                i += 2
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard t.hasPrefix("|") else { break }
                    rows.append(cells(t))
                    i += 1
                }
                blocks.append(.table(rows: rows))
                continue
            }

            if let item = listItem(line) {
                flushParagraph()
                blocks.append(.bullet(indent: item.indent, marker: item.marker, text: item.text))
                i += 1
                continue
            }

            paragraph.append(trimmed)
            i += 1
        }
        flushParagraph()
        return blocks
    }

    private static func isRule(_ t: String) -> Bool {
        let compact = t.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let f = compact.first, "-*_".contains(f) else { return false }
        return compact.allSatisfy { $0 == f }
    }

    private static func heading(_ t: String) -> (Int, String)? {
        let hashes = t.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), t.dropFirst(hashes).first == " " else { return nil }
        return (hashes, t.dropFirst(hashes).trimmingCharacters(in: .whitespaces))
    }

    private static func listItem(_ line: String) -> (indent: Int, marker: String, text: String)? {
        let leading = line.prefix { $0 == " " || $0 == "\t" }
        let indent = leading.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) } / 2
        let rest = line.dropFirst(leading.count)

        if let f = rest.first, "-*+".contains(f), rest.dropFirst().first == " " {
            var text = rest.dropFirst(2).trimmingCharacters(in: .whitespaces)
            var marker = "•"
            if text.hasPrefix("[ ] ") { marker = "☐"; text = String(text.dropFirst(4)) }
            else if text.lowercased().hasPrefix("[x] ") { marker = "☑"; text = String(text.dropFirst(4)) }
            return (indent, marker, text)
        }

        let digits = rest.prefix { $0.isNumber }
        if !digits.isEmpty, digits.count <= 9 {
            let after = rest.dropFirst(digits.count)
            if let d = after.first, d == "." || d == ")", after.dropFirst().first == " " {
                return (indent, "\(digits).", after.dropFirst(2).trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }

    private static func cells(_ row: String) -> [String] {
        var t = row.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("-"), t.contains("|") else { return false }
        return t.allSatisfy { "|-: ".contains($0) }
    }
}

// MARK: - View

struct MarkdownText: View {
    let source: String
    var fontSize: CGFloat = 12.5
    var color: Color = Color(hex: "#B0B5BE")

    private var blocks: [MarkdownBlock] { MarkdownParser.parse(source) }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let text):
            inline(text).font(.system(size: fontSize)).foregroundColor(color)

        case .heading(let level, let text):
            inline(text)
                .font(.system(size: fontSize + CGFloat(max(0, 4 - level)), weight: .semibold))
                .foregroundColor(Color(hex: "#F1F2F4"))
                .padding(.top, 2)

        case .code(_, let text):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text)
                    .font(.system(size: fontSize - 1, design: .monospaced))
                    .foregroundColor(Color(hex: "#D6D9DF"))
                    .fixedSize()
                    .padding(8)
            }
            .background(Color.black.opacity(0.35))
            .clipShape(RoundedRectangle(cornerRadius: 8))

        case .bullet(let indent, let marker, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker)
                    .font(.system(size: fontSize))
                    .foregroundColor(Color(hex: "#6B7079"))
                inline(text).font(.system(size: fontSize)).foregroundColor(color)
            }
            .padding(.leading, CGFloat(min(indent, 4)) * 12)

        case .quote(let text):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1).fill(Color.white.opacity(0.25)).frame(width: 2)
                inline(text).font(.system(size: fontSize)).foregroundColor(Color(hex: "#8E939C"))
            }

        case .table(let rows):
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                ForEach(Array(rows.enumerated()), id: \.offset) { r, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            inline(cell)
                                .font(.system(size: fontSize - 0.5, weight: r == 0 ? .semibold : .regular))
                                .foregroundColor(r == 0 ? Color(hex: "#F1F2F4") : color)
                        }
                    }
                }
            }
            .padding(6)
            .background(Color.white.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 6))

        case .rule:
            Rectangle().fill(Color.white.opacity(0.15)).frame(height: 1).padding(.vertical, 2)
        }
    }

    private func inline(_ text: String) -> Text {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        guard var attributed = try? AttributedString(markdown: text, options: options) else {
            return Text(text)
        }
        for run in attributed.runs {
            if run.inlinePresentationIntent?.contains(.code) == true {
                attributed[run.range].font = .system(size: fontSize - 0.5, design: .monospaced)
                attributed[run.range].backgroundColor = Color.white.opacity(0.12)
            }
        }
        return Text(attributed)
    }
}
