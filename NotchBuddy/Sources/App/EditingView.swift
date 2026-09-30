import SwiftUI
import AppKit

// MARK: - Editing view: live preview of the file the agent is editing

struct EditingView: View {
    @ObservedObject var state: AppState
    @State private var typed = 0
    @State private var typingTask: Task<Void, Never>?

    private static let rowHeight: CGFloat = 20
    private static let mono = Font.system(size: 12, design: .monospaced)

    private var preview: EditPreview? { state.editPreview }
    private var isActive: Bool { state.view == .editing && state.mode == .expanded }

    var body: some View {
        ZStack(alignment: .topLeading) {
            CardBackground(wash: nil)
            if let preview {
                VStack(alignment: .leading, spacing: 0) {
                    tabBar(preview)
                    Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
                    VStack(spacing: 0) {
                        ForEach(preview.lines) { row($0, in: preview) }
                    }
                    .padding(.top, 6)
                }
                .padding(.leading, 92)
                .padding(.trailing, 14)
                .padding(.top, 10)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if let preview { openInEditor(preview) } }
        .onChange(of: preview?.id) { _, _ in restartTyping() }
        .onChange(of: isActive) { _, active in active ? restartTyping() : typingTask?.cancel() }
        .onAppear { restartTyping() }
    }

    // MARK: Tab bar

    private func tabBar(_ p: EditPreview) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 7) {
                LanguageBadge(ext: p.fileExtension)
                Text(p.fileName)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(Color(hex: "#E8E9EC"))
                    .lineLimit(1).truncationMode(.middle)
                Circle().fill(Color(hex: "#E5B454")).frame(width: 6, height: 6)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(
                UnevenRoundedRectangle(topLeadingRadius: 7, topTrailingRadius: 7)
                    .fill(Color.white.opacity(0.055))
            )
            Spacer(minLength: 8)
            Text(p.displayPath)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Color(hex: "#5E6570"))
                .lineLimit(1).truncationMode(.head)
        }
        .frame(height: 28)
    }

    // MARK: Rows

    @ViewBuilder
    private func row(_ line: DiffLine, in p: EditPreview) -> some View {
        let accent: Color? = line.kind == .removed ? Color(hex: "#F4505E")
            : line.kind == .added ? Color(hex: "#34D399") : nil

        HStack(spacing: 0) {
            Rectangle().fill(accent ?? .clear).frame(width: 2)
            Text(line.number.map(String.init) ?? "")
                .font(Self.mono)
                .foregroundColor(accent.map { $0.opacity(0.75) } ?? Color(hex: "#4B515B"))
                .frame(width: 34, alignment: .trailing)
            Text(line.kind == .removed ? "-" : line.kind == .added ? "+" : "")
                .font(Self.mono)
                .foregroundColor(accent ?? .clear)
                .frame(width: 22)
            code(line, in: p)
            Spacer(minLength: 0)
        }
        .frame(height: Self.rowHeight)
        .background(accent.map { $0.opacity(line.kind == .removed ? 0.13 : 0.11) } ?? .clear)
    }

    @ViewBuilder
    private func code(_ line: DiffLine, in p: EditPreview) -> some View {
        switch line.kind {
        case .removed:
            Text(line.text)
                .font(Self.mono)
                .strikethrough(true, color: Color(hex: "#F4505E").opacity(0.7))
                .foregroundColor(Color(hex: "#F4505E").opacity(0.6))
                .lineLimit(1)
        case .context:
            Text(CodeHighlighter.highlight(line.text)).font(Self.mono).lineLimit(1)
        case .added:
            let (visible, hasCursor) = typedSlice(of: line, in: p)
            HStack(spacing: 1) {
                Text(visible).font(Self.mono).lineLimit(1)
                if hasCursor { Caret(blinking: isActive && typed >= totalTyped(p)) }
            }
        }
    }

    // MARK: Typing animation (added lines are typed out, then the caret blinks)

    private func addedOffsets(_ p: EditPreview) -> [Int: Int] {
        var offsets: [Int: Int] = [:]
        var total = 0
        for line in p.lines where line.kind == .added {
            offsets[line.id] = total
            total += line.text.count + 1
        }
        return offsets
    }

    private func totalTyped(_ p: EditPreview) -> Int {
        p.lines.filter { $0.kind == .added }.reduce(0) { $0 + $1.text.count + 1 }
    }

    private func typedSlice(of line: DiffLine, in p: EditPreview) -> (AttributedString, Bool) {
        let full = CodeHighlighter.highlight(line.text)
        let offset = addedOffsets(p)[line.id] ?? 0
        let count = min(max(typed - offset, 0), line.text.count)
        let lastAdded = p.lines.last(where: { $0.kind == .added })?.id
        let typingHere = typed >= offset && typed <= offset + line.text.count
        let done = typed >= totalTyped(p)
        let cursor = done ? line.id == lastAdded : typingHere
        guard count < line.text.count else { return (full, cursor) }
        let end = full.index(full.startIndex, offsetByCharacters: count)
        return (AttributedString(full[full.startIndex..<end]), cursor)
    }

    private func restartTyping() {
        typingTask?.cancel()
        guard let p = preview, isActive else { typed = Int.max / 2; return }
        let total = totalTyped(p)
        typed = 0
        guard total > 0 else { return }
        // ~1s whatever the size, never faster than a comfortable reading pace for short edits
        let step = max(1, Int((Double(total) / 55).rounded(.up)))
        typingTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            while !Task.isCancelled, typed < total {
                typed = min(total, typed + step)
                try? await Task.sleep(nanoseconds: 18_000_000)
            }
        }
    }

    private func openInEditor(_ p: EditPreview) {
        let path = p.filePath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? p.filePath
        if let url = URL(string: "vscode://file\(path)\(p.jumpLine.map { ":\($0)" } ?? "")") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Caret

private struct Caret: View {
    let blinking: Bool

    var body: some View {
        if blinking {
            TimelineView(.periodic(from: .now, by: 0.53)) { context in
                bar.opacity(Int(context.date.timeIntervalSinceReferenceDate / 0.53) % 2 == 0 ? 1 : 0)
            }
        } else {
            bar
        }
    }

    private var bar: some View {
        Rectangle().fill(Color(hex: "#E8E9EC")).frame(width: 1.5, height: 14)
    }
}

// MARK: - Language badge (tiny file-type tile, like an editor tab icon)

private struct LanguageBadge: View {
    let ext: String

    private var style: (label: String, bg: String, fg: String) {
        switch ext {
        case "ts", "mts", "cts": return ("TS", "#3178C6", "#FFFFFF")
        case "tsx":              return ("TSX", "#3178C6", "#FFFFFF")
        case "js", "mjs", "cjs": return ("JS", "#F0D84A", "#1B1B1B")
        case "jsx":              return ("JSX", "#F0D84A", "#1B1B1B")
        case "swift":            return ("SW", "#F05138", "#FFFFFF")
        case "py":               return ("PY", "#3776AB", "#FFD845")
        case "dart":             return ("DA", "#0175C2", "#FFFFFF")
        case "go":               return ("GO", "#00ADD8", "#FFFFFF")
        case "rs":               return ("RS", "#DEA584", "#1B1B1B")
        case "kt", "kts":        return ("KT", "#7F52FF", "#FFFFFF")
        case "java":             return ("JV", "#B07219", "#FFFFFF")
        case "json":             return ("{}", "#CBCB41", "#1B1B1B")
        case "md", "mdx":        return ("MD", "#519ABA", "#FFFFFF")
        case "html", "htm":      return ("<>", "#E34C26", "#FFFFFF")
        case "css", "scss":      return ("#", "#663399", "#FFFFFF")
        case "sh", "zsh", "bash": return ("SH", "#4EAA25", "#FFFFFF")
        case "yml", "yaml":      return ("YML", "#CB171E", "#FFFFFF")
        default:
            let label = ext.isEmpty ? "•" : String(ext.prefix(2)).uppercased()
            return (label, "#3A3F47", "#C9CDD4")
        }
    }

    var body: some View {
        let s = style
        Text(s.label)
            .font(.system(size: s.label.count > 2 ? 6.5 : 8, weight: .heavy, design: .rounded))
            .foregroundColor(Color(hex: s.fg))
            .frame(width: 16, height: 14)
            .background(RoundedRectangle(cornerRadius: 3).fill(Color(hex: s.bg)))
    }
}
