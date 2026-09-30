import Foundation
import Darwin
import AppKit

// MARK: - HookServer
// Listens on a Unix domain socket for events from nb-hook (Claude Code hooks).
// Thread-safe: socket I/O on background threads, state updates dispatched to main queue.

final class HookServer: @unchecked Sendable {
    static let shared = HookServer()

    // Support directory paths
    static var supportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchBuddy")
    }
    static var socketPath: String { supportDir.appendingPathComponent("nb.sock").path }
    static var hookScriptPath: String {
        #if APPSTORE
        // Written to ~/.claude/coucou/nb-hook via security-scoped bookmark during hook installation
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/coucou/nb-hook").path
        #else
        return supportDir.appendingPathComponent("nb-hook").path
        #endif
    }

    // No approval blocking state — notch is notification-only, user answers in VS Code

    private var serverFD: Int32 = -1
    /// Approvals waiting on the user, shown one at a time (first = on screen). Main actor only.
    private var approvalQueue: [PendingApproval] = []
    private var copilotAlwaysAllowedTools: Set<String> = []
    private var editPreviewTimer: DispatchWorkItem?
    private var editPreviewOpenedIsland = false
    private var activeSessionId: String? = nil  // current Claude Code session

    private init() {}

    // MARK: - Start

    func start() {
        #if !APPSTORE
        installHookScript()
        // Rewrite older installs that lack events or the --vscode flag
        if Self.copilotVSCodeHooksInstalled { try? writeCopilotVSCodeHooks() }
        #endif
        Thread.detachNewThread { self.serverThread() }
    }

    // MARK: - Socket server (background thread)

    private func serverThread() {
        let path = Self.socketPath
        try? FileManager.default.removeItem(atPath: path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        serverFD = fd

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let cpath = Array(path.utf8CString)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, c) in cpath.enumerated() where i < raw.count { raw[i] = UInt8(bitPattern: c) }
        }

        let bindRC = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bindRC == 0 else { close(fd); return }
        guard Darwin.listen(fd, 10) == 0 else { close(fd); return }

        while true {
            let clientFD = Darwin.accept(fd, nil, nil)
            guard clientFD >= 0 else { break }
            Thread.detachNewThread { self.handleClient(fd: clientFD) }
        }
    }

    // MARK: - Client handler (background thread)

    private func handleClient(fd: Int32) {
        // Read newline-delimited JSON
        var raw = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        outer: while true {
            let n = recv(fd, &buf, buf.count, 0)
            if n <= 0 { break }
            for i in 0..<n {
                if buf[i] == UInt8(ascii: "\n") { break outer }
                raw.append(buf[i])
            }
        }

        guard !raw.isEmpty,
              let payload = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            sendLine(fd: fd, text: #"{"ok":true}"#)
            close(fd)
            return
        }

        let eventName = payload["hook_event_name"] as? String ?? ""

        if eventName == "PermissionRequest" {
            // Hold fd open — Claude Code waits for our decision (up to 120s)
            Task { @MainActor in self.processPermissionRequest(fd: fd, payload: payload) }
        } else if eventName == "PreToolUse" && payload["harness"] as? String == "vscode" {
            // VS Code's Local harness has no PermissionRequest: the hook waits on PreToolUse instead
            Task { @MainActor in self.processVSCodePreToolUse(fd: fd, payload: payload) }
        } else {
            Task { @MainActor in self.processEvent(name: eventName, payload: payload) }
            sendLine(fd: fd, text: #"{"ok":true}"#)
            close(fd)
        }
    }


    // MARK: - Event → AppState
    // All Claude Code events route to the permanent "integration_claude" task.
    // View switches only happen if VS Code is the currently focused mochi.
    // When not focused: state updates animate the mini bot in the pill; badge shown for alerts.

    @MainActor
    private func processEvent(name: String, payload: [String: Any]) {
        let state = AppState.shared
        let sessionId = payload["session_id"] as? String ?? "unknown"
        let cwd = payload["cwd"] as? String ?? ""
        let rawName = URL(fileURLWithPath: cwd).lastPathComponent
        let projectName = aliasProjectName(rawName.isEmpty ? "Session" : rawName)

        let termProgram = payload["term_program"] as? String ?? ""
        let bundleId    = payload["bundle_id"]    as? String ?? ""
        let isVSCode = termProgram.lowercased().contains("vscode") ||
                       bundleId.lowercased().contains("vscode") ||
                       payload["agent"] as? String == "copilot"
        guard isVSCode else {
            nbLog("Ignored \(name) from \(termProgram.isEmpty ? bundleId : termProgram) (\(projectName))")
            return
        }

        let focused = state.focusId == "integration_claude"

        // The agent moved on, so a VS Code-only permission prompt has been answered there
        if name != "Notification", state.pendingApproval?.answerInVSCode == true, approvalQueue.isEmpty {
            finishApprovalUI()
        }

        switch name {

        case "SessionStart":
            // VS Code's Local harness never sends SessionEnd: a new Copilot session replaces the old one
            if payload["agent"] as? String == "copilot", activeSessionId != sessionId { clearSession() }
            activeSessionId = sessionId
            upsertTask(projectName: projectName, cwd: cwd, payload: payload)
            nbLog("SessionStart \(projectName) (\(sessionId.prefix(8)))")
            if state.isPresent { expandIfNeeded(to: .overview) }
            SoundEngine.shared.play("work")

        case "UserPromptSubmit":
            activeSessionId = sessionId
            upsertTask(projectName: projectName, cwd: cwd, payload: payload)
            state.updateTask(id: "integration_claude", state: .thinking)
            if let message = (payload["message"] as? String) ?? (payload["prompt"] as? String), !message.isEmpty {
                appendStep(id: "integration_claude", step: String(message.prefix(60)))
            }
            if state.isPresent { expandIfNeeded(to: .overview) }

        case "PreToolUse":
            activeSessionId = sessionId
            upsertTask(projectName: projectName, cwd: cwd, payload: payload)
            state.updateTask(id: "integration_claude", state: .working)
            let tool = payload["tool_name"] as? String ?? "Tool"
            let input = payload["tool_input"] as? [String: Any] ?? [:]
            let step = frenchStep(tool: tool, input: input)
            appendStep(id: "integration_claude", step: step)
            nbLog("PreToolUse \(step)")
            showEditPreview(tool: tool, input: input, cwd: cwd, focused: focused)

        case "PostToolUse":
            state.updateTask(id: "integration_claude", state: .working)

        case "PostToolUseFailure":
            state.updateTask(id: "integration_claude", state: .working)
            appendStep(id: "integration_claude", step: "⚠ failed")

        case "Notification":
            let message = payload["message"] as? String ?? ""
            let lower = message.lowercased()
            if lower.contains("rate limit") || lower.contains("limite d") {
                state.updateTask(id: "integration_claude", state: .ratelimit)
                SoundEngine.shared.play("rate")
            } else if payload["notification_type"] as? String == "permission_prompt",
                      payload["agent"] as? String == "copilot", approvalQueue.isEmpty {
                // Read/path permissions skip the permissionRequest hook: point the user to VS Code
                nbLog("Permission prompt in VS Code: \(message)")
                upsertTask(projectName: projectName, cwd: cwd, payload: payload)
                state.updateTask(id: "integration_claude", state: .approval)
                state.pendingApproval = ApprovalInfo(sessionId: sessionId,
                                                     tool: payload["title"] as? String ?? "Permission needed",
                                                     command: message, isCopilot: true, answerInVSCode: true)
                SoundEngine.shared.play("approval")
                if focused { expandIfNeeded(to: .approval) }
                else { setPillBadge(id: "integration_claude", badge: .approval) }
            } else if payload["notification_type"] as? String == "elicitation_dialog" || message.hasSuffix("?") {
                state.updateTask(id: "integration_claude", state: .question)
                appendStep(id: "integration_claude", step: message)
            }

        case "Stop":
            upsertTask(projectName: projectName, cwd: cwd, payload: payload)
            state.updateTask(id: "integration_claude", state: .finished)
            if let message = payload["message"] as? String, !message.isEmpty {
                appendStep(id: "integration_claude", step: String(message.prefix(60)))
            }
            SoundEngine.shared.play("finish")
            if focused {
                expandIfNeeded(to: .finished)
            } else {
                setPillBadge(id: "integration_claude", badge: .finished)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.2) {
                state.updateTask(id: "integration_claude", state: .idle)
                self.clearPillBadge(id: "integration_claude")
            }

        case "ErrorOccurred" where payload["recoverable"] as? Bool == true:
            // Copilot retries these itself (e.g. model call timeouts): note it, keep working
            appendStep(id: "integration_claude", step: "⚠ " + String(errorSummary(payload).prefix(58)))

        case "StopFailure", "ErrorOccurred":
            state.updateTask(id: "integration_claude", state: .error)
            SoundEngine.shared.play("error")
            if focused {
                expandIfNeeded(to: .error)
            } else {
                setPillBadge(id: "integration_claude", badge: .error)
            }

        case "SessionEnd":
            activeSessionId = nil
            state.updateTask(id: "integration_claude", state: .idle)
            clearSession()

        case "SubagentStart":
            let name = (payload["agent_display_name"] ?? payload["agent_name"] ?? payload["agent_type"]) as? String
            appendStep(id: "integration_claude", step: name.map { "+ subagent · \($0)" } ?? "+ subagent")

        case "SubagentStop":
            appendStep(id: "integration_claude", step: "• subagent done")

        default:
            break
        }
    }

    // MARK: - Helpers

    /// Shows the file being edited in the .editing view, then goes back after a short pause.
    /// Only while VS Code is the focused mochi and nothing more important is on screen.
    @MainActor
    private func showEditPreview(tool: String, input: [String: Any], cwd: String, focused: Bool) {
        guard let preview = EditPreviewBuilder.build(tool: tool, input: input, cwd: cwd) else { return }
        let state = AppState.shared
        state.editPreview = preview
        guard focused, state.isPresent, approvalQueue.isEmpty, state.pendingApproval == nil else { return }

        if state.mode == .expanded {
            guard [.overview, .empty, .editing, .finished].contains(state.view) else { return }
            state.view = .editing
        } else {
            editPreviewOpenedIsland = true
            NotificationCenter.default.post(name: .hookExpand, object: IslandView.editing)
        }

        editPreviewTimer?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.endEditPreview() }
        }
        editPreviewTimer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.5, execute: item)
    }

    @MainActor
    private func endEditPreview() {
        let state = AppState.shared
        let openedByUs = editPreviewOpenedIsland
        editPreviewOpenedIsland = false
        guard state.view == .editing else { return }
        state.view = state.tasks.isEmpty ? .empty : .overview
        // We popped the island open just for the preview: fold it back to compact
        if openedByUs { NotificationCenter.default.post(name: .islandCollapse, object: nil) }
    }

    @MainActor
    private func expandIfNeeded(to view: IslandView) {
        let state = AppState.shared
        let isAlert: Bool
        switch view {
        case .approval, .finished, .error, .confused: isAlert = true
        default: isAlert = false
        }
        if state.mode == .expanded {
            // Only force-switch view for alerts — leave user on their current view otherwise
            if isAlert { state.view = view }
        } else if isAlert {
            // Alerts always force-expand
            NotificationCenter.default.post(name: .hookExpand, object: view)
        } else if state.mode == .hidden {
            // Non-alert work events: reveal compact only, never force-expand
            NotificationCenter.default.post(name: .hookReveal, object: nil)
        }
        // Already compact and non-alert: Mochi state update is enough, no expand
    }

    // MARK: - Permission request (blocking — Claude Code waits for decision)

    @MainActor
    private func processPermissionRequest(fd: Int32, payload: [String: Any]) {
        let state = AppState.shared
        let sessionId = payload["session_id"] as? String ?? "unknown"
        let cwd       = payload["cwd"]        as? String ?? ""
        let rawName   = URL(fileURLWithPath: cwd).lastPathComponent
        let projectName = aliasProjectName(rawName.isEmpty ? "Session" : rawName)

        let termProgram = payload["term_program"] as? String ?? ""
        let bundleId    = payload["bundle_id"]    as? String ?? ""
        let isVSCode = termProgram.lowercased().contains("vscode") ||
                       bundleId.lowercased().contains("vscode") ||
                       payload["agent"] as? String == "copilot"
        guard isVSCode else {
            Task.detached { [weak self] in
                self?.sendLine(fd: fd, text: #"{"permissionDecision":"ask"}"#)
                close(fd)
            }
            return
        }

        let tool = payload["tool_name"] as? String ?? "Tool"
        let input = payload["tool_input"] as? [String: Any] ?? [:]
        let command = approvalSummary(tool: tool, input: input)
        // Copilot (VS Code or CLI) keeps its own prompt: an unanswered request hands back to it
        let fromCopilot = payload["agent"] as? String == "copilot"
        let alwaysKey = "\(sessionId)|\(tool)"
        if fromCopilot && copilotAlwaysAllowedTools.contains(alwaysKey) {
            nbLog("PermissionRequest \(tool) auto-allowed (Always)")
            Task.detached { [weak self] in
                self?.sendLine(fd: fd, text: #"{"permissionDecision":"allow"}"#)
                close(fd)
            }
            return
        }
        nbLog("PermissionRequest \(tool): \(command)")

        let token = UUID()
        approvalQueue.append(PendingApproval(
            token: token, fd: fd, isCopilot: fromCopilot, alwaysKey: alwaysKey,
            info: ApprovalInfo(sessionId: sessionId, tool: tool, command: command, isCopilot: fromCopilot),
            projectName: projectName, cwd: cwd, payload: payload))
        watchForHangup(fd: fd, token: token)

        // Unanswered: Copilot falls back to its own confirmation, Claude Code gets a deny
        DispatchQueue.main.asyncAfter(deadline: .now() + 115) { [weak self] in
            self?.answerApproval(token: token, decision: fromCopilot ? "ask" : "deny")
        }

        if approvalQueue.count == 1 {
            presentCurrentApproval()
        } else {
            // Parallel tool calls: keep the one on screen, queue this one behind it
            AppState.shared.pendingApproval?.moreWaiting = approvalQueue.count - 1
        }
    }

    /// Shows the first queued approval, or restores the normal view when none are left.
    @MainActor
    private func presentCurrentApproval() {
        guard let current = approvalQueue.first else {
            finishApprovalUI()
            return
        }
        let state = AppState.shared
        activeSessionId = current.info.sessionId
        upsertTask(projectName: current.projectName, cwd: current.cwd, payload: current.payload)
        state.updateTask(id: "integration_claude", state: .approval)
        var info = current.info
        info.moreWaiting = approvalQueue.count - 1
        state.pendingApproval = info
        state.isPinned = true
        SoundEngine.shared.play("approval")

        if state.focusId == "integration_claude" {
            expandIfNeeded(to: .approval)
        } else {
            setPillBadge(id: "integration_claude", badge: .approval)
        }
    }

    // MARK: - VS Code Local harness: PreToolUse doubles as the approval hook

    /// Tools that VS Code would normally confirm: terminal commands, tasks, web fetches and MCP tools.
    static func vsCodeToolNeedsApproval(_ tool: String) -> Bool {
        let lower = tool.lowercased()
        if lower.hasPrefix("mcp_") || lower.hasPrefix("mcp.") { return true }
        let t = lower.replacingOccurrences(of: "_", with: "")
        return t.contains("runinterminal") || t.hasSuffix("runtask") || t.contains("createandruntask")
            || t.contains("fetchwebpage") || t == "fetch"
    }

    @MainActor
    private func processVSCodePreToolUse(fd: Int32, payload: [String: Any]) {
        processEvent(name: "PreToolUse", payload: payload)

        let tool = payload["tool_name"] as? String ?? ""
        guard Self.vsCodeToolNeedsApproval(tool) else {
            Task.detached { [weak self] in
                self?.sendLine(fd: fd, text: #"{"ok":true}"#)
                close(fd)
            }
            return
        }
        processPermissionRequest(fd: fd, payload: payload)
    }

    /// Clears the notch when the waiting hook goes away (agent cancelled or hook timed out).
    private func watchForHangup(fd: Int32, token: UUID) {
        let watchFD = dup(fd)
        guard watchFD >= 0 else { return }
        Thread.detachNewThread { [weak self] in
            var pfd = pollfd(fd: watchFD, events: Int16(POLLIN), revents: 0)
            while poll(&pfd, 1, -1) < 0 && errno == EINTR {}
            var byte: UInt8 = 0
            let n = recv(watchFD, &byte, 1, MSG_PEEK)
            close(watchFD)
            guard n <= 0 else { return }
            Task { @MainActor in self?.approvalHookGone(token: token) }
        }
    }

    @MainActor
    private func approvalHookGone(token: UUID) {
        guard let idx = approvalQueue.firstIndex(where: { $0.token == token }) else { return }
        nbLog("Approval request withdrawn")
        let entry = approvalQueue.remove(at: idx)
        close(entry.fd)
        if idx == 0 { presentCurrentApproval() }
        else { AppState.shared.pendingApproval?.moreWaiting = approvalQueue.count - 1 }
    }

    /// Called by ApprovalView buttons for the approval on screen.
    /// "ask" hands the decision back to the agent's own prompt (Copilot only).
    @MainActor
    func sendApprovalDecision(_ decision: String) {
        guard let current = approvalQueue.first else {
            finishApprovalUI()
            return
        }
        answerApproval(token: current.token, decision: decision)
    }

    /// Dismisses a VS Code-only permission notice (nothing is waiting on the socket).
    @MainActor
    func dismissApprovalNotice() {
        guard AppState.shared.pendingApproval?.answerInVSCode == true, approvalQueue.isEmpty else { return }
        finishApprovalUI()
    }

    /// Writes the decision to the waiting nb-hook, then moves on to the next queued approval.
    @MainActor
    private func answerApproval(token: UUID, decision: String) {
        guard let idx = approvalQueue.firstIndex(where: { $0.token == token }) else { return }
        let headBefore = approvalQueue.first?.token
        let entry = approvalQueue.remove(at: idx)

        let json: String
        switch decision {
        case "allow":  json = #"{"permissionDecision":"allow"}"#
        case "always": json = #"{"permissionDecision":"allow","alwaysAllow":true}"#
        case "ask" where entry.isCopilot: json = #"{"permissionDecision":"ask"}"#
        default:       json = #"{"permissionDecision":"deny"}"#
        }
        reply(fd: entry.fd, text: json)

        if decision == "always" {
            if entry.isCopilot {
                copilotAlwaysAllowedTools.insert(entry.alwaysKey)
                // Same tool in the same session is already waiting behind: allow it too
                for other in approvalQueue where other.alwaysKey == entry.alwaysKey {
                    reply(fd: other.fd, text: #"{"permissionDecision":"allow"}"#)
                }
                approvalQueue.removeAll { $0.alwaysKey == entry.alwaysKey }
            } else {
                AppState.shared.alwaysAllow = true
            }
        }

        if approvalQueue.first?.token != headBefore { presentCurrentApproval() }
        else { AppState.shared.pendingApproval?.moreWaiting = approvalQueue.count - 1 }
    }

    /// Sends one JSON line to a waiting nb-hook and ends the connection.
    private func reply(fd: Int32, text: String) {
        Task.detached { [weak self] in
            self?.sendLine(fd: fd, text: text)
            // Shutdown (not just close) so the hangup watcher's dup'ed fd doesn't keep the socket open
            shutdown(fd, SHUT_RDWR)
            close(fd)
        }
    }

    @MainActor
    private func finishApprovalUI() {
        let state = AppState.shared
        state.pendingApproval = nil
        state.isPinned = false
        state.updateTask(id: "integration_claude", state: .working)
        clearPillBadge(id: "integration_claude")
        if state.view == .approval { state.view = state.tasks.isEmpty ? .empty : .overview }
    }

    private func approvalSummary(tool: String, input: [String: Any]) -> String {
        if let cmd = input["command"] as? String, !cmd.isEmpty { return cmd }
        if let urls = input["urls"] as? [String], !urls.isEmpty { return urls.joined(separator: "\n") }
        if let url = input["url"] as? String, !url.isEmpty { return url }
        if let task = input["task_label"] as? String ?? input["label"] as? String ?? input["id"] as? String {
            return "\(tool) · \(task)"
        }
        return tool
    }

    /// Updates integration_claude with the current session project name, cwd and agent.
    @MainActor
    private func upsertTask(projectName: String, cwd: String = "", payload: [String: Any]) {
        let state = AppState.shared
        guard let idx = state.tasks.firstIndex(where: { $0.id == "integration_claude" }) else { return }
        state.tasks[idx].name = projectName
        if !cwd.isEmpty { state.tasks[idx].sessionCwd = cwd }
        // VS Code's Copilot also loads ~/.claude/settings.json hooks: those events arrive tagged "claude"
        let aiAgent = (payload["ai_agent"] as? String ?? "").lowercased()
        let agent = aiAgent.contains("copilot") ? "copilot" : payload["agent"] as? String
        switch agent {
        case "copilot":
            // Copilot running inside VS Code (either harness) vs Copilot CLI in a terminal
            let host = ((payload["bundle_id"] as? String ?? "") + (payload["term_program"] as? String ?? "")
                        + (payload["ai_agent"] as? String ?? "")).lowercased()
            let inVSCode = payload["harness"] as? String == "vscode" || host.contains("vscode")
            // Once a session is seen in VS Code it stays there, whatever later hooks report
            state.tasks[idx].agentLabel = (inVSCode || state.tasks[idx].agentLabel == "Copilot") ? "Copilot" : "Copilot CLI"
        case "claude":
            state.tasks[idx].agentLabel = "Claude Code"
        default:
            break
        }
    }

    /// Human-readable text of an ErrorOccurred payload (the message may itself be a JSON error body).
    private func errorSummary(_ payload: [String: Any]) -> String {
        var message = (payload["error"] as? [String: Any])?["message"] as? String
            ?? payload["error"] as? String ?? "error"
        if let data = message.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let inner = json["message"] as? String {
            message = inner
        }
        return message
    }

    // MARK: - Badge helpers

    @MainActor
    private func setPillBadge(id: String, badge: PillBadge) {
        let state = AppState.shared
        guard let idx = state.tasks.firstIndex(where: { $0.id == id }) else { return }
        state.tasks[idx].pillBadge = badge
    }

    @MainActor
    private func clearPillBadge(id: String) {
        let state = AppState.shared
        guard let idx = state.tasks.firstIndex(where: { $0.id == id }) else { return }
        state.tasks[idx].pillBadge = nil
    }

    /// Resets integration_claude to idle, clears steps and project name.
    @MainActor
    private func clearSession() {
        let state = AppState.shared
        guard let idx = state.tasks.firstIndex(where: { $0.id == "integration_claude" }) else { return }
        state.tasks[idx].steps = []
        state.tasks[idx].stepIndex = 0
        state.tasks[idx].name = "VS Code"
        state.tasks[idx].pillBadge = nil
        state.tasks[idx].agentLabel = nil
    }

    @MainActor
    private func appendStep(id: String, step: String) {
        let state = AppState.shared
        guard let idx = state.tasks.firstIndex(where: { $0.id == id }) else { return }
        state.tasks[idx].steps.append(step)
        if state.tasks[idx].steps.count > 20 { state.tasks[idx].steps.removeFirst() }
        state.tasks[idx].stepIndex = state.tasks[idx].steps.count - 1
    }

    // MARK: - Project name alias mapping

    private func aliasProjectName(_ name: String) -> String {
        let aliases: [String: String] = [
            "notch-buddy":  "Notch Buddy",
            "notchbuddy":   "Notch Buddy",
            "notch_buddy":  "Notch Buddy",
        ]
        return aliases[name.lowercased()] ?? name
    }

    // MARK: - French step labels

    private func frenchStep(tool: String, input: [String: Any]) -> String {
        let labels: [String: String] = [
            "Bash":       "Exécute",
            "Read":       "Lit",
            "Write":      "Écrit",
            "Edit":       "Modifie",
            "Glob":       "Cherche",
            "Grep":       "Recherche",
            "WebSearch":  "Recherche web",
            "WebFetch":   "Récupère",
            "TodoWrite":  "Tâches",
            "Task":       "Agent",
            "LS":         "Liste",
            "MultiEdit":  "Modifie",
            "NotebookEdit": "Notebook",
            // VS Code Local harness
            "run_in_terminal":              "Exécute",
            "read_file":                    "Lit",
            "create_file":                  "Écrit",
            "replace_string_in_file":       "Modifie",
            "multi_replace_string_in_file": "Modifie",
            "insert_edit_into_file":        "Modifie",
            "apply_patch":                  "Modifie",
            "edit_notebook_file":           "Notebook",
            "file_search":                  "Cherche",
            "grep_search":                  "Recherche",
            "semantic_search":              "Recherche",
            "list_dir":                     "Liste",
            "fetch_webpage":                "Récupère",
            "manage_todo_list":             "Tâches",
            "runSubagent":                  "Agent",
            // Copilot SDK runtime names (Agent Host / CLI tools without a Claude equivalent)
            "Agent":                        "Agent",
            "AskUserQuestion":              "Question",
            "bash":                         "Exécute",
            "view":                         "Lit",
            "create":                       "Écrit",
            "edit":                         "Modifie",
            "web_fetch":                    "Récupère",
            "ask_user":                     "Question",
        ]
        let label = labels[tool] ?? tool
        if let cmd = input["command"] as? String {
            let short = String(cmd.prefix(40))
            return "\(label) · \(short)"
        } else if let path = (input["path"] ?? input["filePath"] ?? input["dirPath"]) as? String {
            return "\(label) · \(URL(fileURLWithPath: path).lastPathComponent)"
        } else if let file = input["file_path"] as? String {
            return "\(label) · \(URL(fileURLWithPath: file).lastPathComponent)"
        } else if let query = input["query"] as? String {
            return "\(label) · \(String(query.prefix(40)))"
        } else if let url = (input["urls"] as? [String])?.first ?? input["url"] as? String {
            return "\(label) · \(String(url.prefix(40)))"
        }
        return label
    }

    // MARK: - Logging

    private func nbLog(_ message: String) {
        let logsDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/NotchBuddy")
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        let logFile = logsDir.appendingPathComponent("nb.log")
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let line = "\(formatter.string(from: Date())) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: logFile.path) {
            if let handle = try? FileHandle(forWritingTo: logFile) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            }
        } else {
            try? data.write(to: logFile)
        }
    }

    private func sendLine(fd: Int32, text: String) {
        // `&bytes[i]` would point at a temporary one-byte copy, so send from the buffer itself
        let bytes = Array((text + "\n").utf8)
        bytes.withUnsafeBytes { buf in
            guard let base = buf.baseAddress else { return }
            var sent = 0
            while sent < buf.count {
                let n = Darwin.send(fd, base + sent, buf.count - sent, 0)
                if n <= 0 { break }
                sent += n
            }
        }
    }

    // MARK: - nb-hook script installation

    func installHookScript() {
        #if APPSTORE
        // In App Store mode the script is written during settings hook installation
        // (requires a security-scoped bookmark to ~/.claude chosen by the user)
        #else
        let dir = Self.supportDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let scriptURL = URL(fileURLWithPath: Self.hookScriptPath)
        try? nbHookScript.write(to: scriptURL, atomically: true, encoding: .utf8)
        _ = try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755 as NSNumber],
            ofItemAtPath: scriptURL.path
        )
        #endif
    }

    // MARK: - Claude Code settings.json hook installer

    private var _pendingHooksData: Data?

    /// Returns preview JSON without writing — call writeClaudeHooks() to confirm.
    func previewClaudeHooks() throws -> String {
        let data = try buildHooksData()
        _pendingHooksData = data
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Writes the hooks to disk (call after user confirms preview).
    func writeClaudeHooks() throws {
        guard let data = _pendingHooksData else { return }
        let settingsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
        // Backup first
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        let stamp = formatter.string(from: Date())
        let backupURL = settingsURL.deletingLastPathComponent()
            .appendingPathComponent("settings.json.bak-\(stamp)")
        try? FileManager.default.copyItem(at: settingsURL, to: backupURL)
        try? FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(),
                                                  withIntermediateDirectories: true)
        try data.write(to: settingsURL, options: .atomic)
        _pendingHooksData = nil
    }

    private func buildHooksData() throws -> Data {
        let settingsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
        var settings: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsURL),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings = parsed
        }
        let hookPath = Self.hookScriptPath
        #if APPSTORE
        // Sandboxed apps create quarantined files; /bin/sh bypasses the quarantine flag
        let quotedCmd = "/bin/sh \"\(hookPath.replacingOccurrences(of: "\"", with: "\\\""))\""
        #else
        let quotedCmd = "\"\(hookPath.replacingOccurrences(of: "\"", with: "\\\""))\""
        #endif
        let events: [(String, Int)] = [
            ("SessionStart", 10), ("SessionEnd", 10),
            ("UserPromptSubmit", 10),
            ("PreToolUse", 10), ("PostToolUse", 10), ("PostToolUseFailure", 10),
            ("PermissionRequest", 10),
            ("Notification", 10),
            ("Stop", 10), ("StopFailure", 10),
            ("SubagentStart", 10), ("SubagentStop", 10),
        ]
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for (event, timeout) in events {
            var existing = hooks[event] as? [[String: Any]] ?? []
            existing.removeAll { ($0["hooks"] as? [[String: Any]])?.contains { ($0["command"] as? String)?.contains("NotchBuddy") == true || ($0["command"] as? String)?.contains("coucou") == true } ?? false }
            existing.append(["hooks": [["type": "command", "command": quotedCmd, "timeout": timeout]]])
            hooks[event] = existing
        }
        settings["hooks"] = hooks
        return try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
    }

    func uninstallClaudeHooks() throws {
        let settingsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
        guard let data = try? Data(contentsOf: settingsURL),
              var settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var hooks = settings["hooks"] as? [String: Any] else { return }

        for key in hooks.keys {
            if var matchers = hooks[key] as? [[String: Any]] {
                matchers.removeAll { matcher in
                    (matcher["hooks"] as? [[String: Any]])?.contains {
                        ($0["command"] as? String)?.contains("NotchBuddy") == true ||
                        ($0["command"] as? String)?.contains("coucou") == true
                    } ?? false
                }
                if matchers.isEmpty { hooks.removeValue(forKey: key) }
                else { hooks[key] = matchers }
            }
        }
        settings["hooks"] = hooks
        let newData = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try newData.write(to: settingsURL, options: .atomic)
    }

    // MARK: - Copilot CLI hook installer
    // Copilot CLI loads every *.json in ~/.copilot/hooks/ (or $COPILOT_HOME/hooks/).
    // PascalCase event names make it send Claude-compatible snake_case payloads.

    static var copilotHooksURL: URL {
        let home = ProcessInfo.processInfo.environment["COPILOT_HOME"]
            .map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".copilot")
        return home.appendingPathComponent("hooks/coucou.json")
    }

    static var copilotHooksInstalled: Bool {
        FileManager.default.fileExists(atPath: copilotHooksURL.path)
    }

    func previewCopilotHooks() throws -> String {
        String(data: try buildCopilotHooksData(), encoding: .utf8) ?? ""
    }

    func writeCopilotHooks() throws {
        let data = try buildCopilotHooksData()
        let url = Self.copilotHooksURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    func uninstallCopilotHooks() throws {
        try? FileManager.default.removeItem(at: Self.copilotHooksURL)
    }

    private func buildCopilotHooksData() throws -> Data {
        let hookPath = Self.hookScriptPath.replacingOccurrences(of: "\"", with: "\\\"")
        let command = "\"\(hookPath)\" --copilot"
        // Approvals wait on the user, so PermissionRequest gets a long timeout (timeouts fail open).
        let events: [(String, Int)] = [
            ("SessionStart", 10), ("SessionEnd", 10),
            ("UserPromptSubmit", 10),
            ("PreToolUse", 10), ("PostToolUse", 10), ("PostToolUseFailure", 10),
            ("PermissionRequest", 120),
            ("Notification", 10),
            ("Stop", 10), ("SubagentStop", 10),
            ("ErrorOccurred", 10),
        ]
        var hooks: [String: Any] = [:]
        for (event, timeout) in events {
            hooks[event] = [["type": "command", "bash": command, "timeoutSec": timeout]]
        }
        let config: [String: Any] = ["version": 1, "hooks": hooks]
        return try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
    }

    // MARK: - VS Code Copilot hook installer (no Copilot CLI needed)
    // Both VS Code harnesses read ~/.copilot/hooks/*.json:
    // - Agent Host (Copilot SDK) fires the same events as Copilot CLI, approvals use PermissionRequest.
    // - Local harness has no SessionEnd, PermissionRequest or Notification (unknown keys are skipped),
    //   so approvals ride on PreToolUse: the hook waits for a notch decision and answers with
    //   hookSpecificOutput.permissionDecision.
    // nb-hook tells them apart with the COPILOT_CLI env var set by the SDK.

    static var copilotVSCodeHooksURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".copilot/hooks/coucou-vscode.json")
    }

    static var copilotVSCodeHooksInstalled: Bool {
        FileManager.default.fileExists(atPath: copilotVSCodeHooksURL.path)
    }

    func writeCopilotVSCodeHooks() throws {
        let hookPath = Self.hookScriptPath.replacingOccurrences(of: "\"", with: "\\\"")
        let command = "\"\(hookPath)\" --copilot --vscode"
        // PreToolUse (Local) and PermissionRequest (Agent Host) may wait on the user in the notch;
        // the app hands back to VS Code at 115s
        let events: [(String, Int)] = [
            ("SessionStart", 10), ("SessionEnd", 10),
            ("UserPromptSubmit", 10),
            ("PreToolUse", 120), ("PostToolUse", 10), ("PostToolUseFailure", 10),
            ("PermissionRequest", 120),
            ("Notification", 10),
            ("Stop", 10), ("SubagentStart", 10), ("SubagentStop", 10),
            ("ErrorOccurred", 10),
        ]
        var hooks: [String: Any] = [:]
        for (event, timeout) in events {
            hooks[event] = [["type": "command", "command": command, "timeout": timeout]]
        }
        let data = try JSONSerialization.data(withJSONObject: ["hooks": hooks],
                                              options: [.prettyPrinted, .sortedKeys])
        let url = Self.copilotVSCodeHooksURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    func uninstallCopilotVSCodeHooks() throws {
        try? FileManager.default.removeItem(at: Self.copilotVSCodeHooksURL)
    }

    // MARK: - App Store: hooks via security-scoped bookmark

    #if APPSTORE
    /// App Store variant — needs a security-scoped bookmark URL pointing to ~/.claude
    func previewClaudeHooksAppStore(claudeURL: URL) throws -> String {
        let accessing = claudeURL.startAccessingSecurityScopedResource()
        defer { if accessing { claudeURL.stopAccessingSecurityScopedResource() } }
        let data = try buildHooksData(claudeURL: claudeURL)
        _pendingHooksData = data
        return String(data: data, encoding: .utf8) ?? ""
    }

    func writeClaudeHooksAppStore(claudeURL: URL) throws {
        guard let data = _pendingHooksData else { return }
        let accessing = claudeURL.startAccessingSecurityScopedResource()
        defer { if accessing { claudeURL.stopAccessingSecurityScopedResource() } }

        // Write the nb-hook script into ~/.claude/coucou/nb-hook
        let coucouDir = claudeURL.appendingPathComponent("coucou")
        try FileManager.default.createDirectory(at: coucouDir, withIntermediateDirectories: true)
        let scriptURL = coucouDir.appendingPathComponent("nb-hook")
        try nbHookScriptAppStore.write(to: scriptURL, atomically: true, encoding: .utf8)
        _ = try? FileManager.default.setAttributes([.posixPermissions: 0o755 as NSNumber], ofItemAtPath: scriptURL.path)

        // Write settings.json (with backup)
        let settingsURL = claudeURL.appendingPathComponent("settings.json")
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        let backupURL = claudeURL.appendingPathComponent("settings.json.bak-\(formatter.string(from: Date()))")
        try? FileManager.default.copyItem(at: settingsURL, to: backupURL)
        try data.write(to: settingsURL, options: .atomic)
        _pendingHooksData = nil
    }

    func uninstallClaudeHooksAppStore(claudeURL: URL) throws {
        let accessing = claudeURL.startAccessingSecurityScopedResource()
        defer { if accessing { claudeURL.stopAccessingSecurityScopedResource() } }
        let settingsURL = claudeURL.appendingPathComponent("settings.json")
        guard let data = try? Data(contentsOf: settingsURL),
              var settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var hooks = settings["hooks"] as? [String: Any] else { return }
        for key in hooks.keys {
            if var matchers = hooks[key] as? [[String: Any]] {
                matchers.removeAll { matcher in
                    (matcher["hooks"] as? [[String: Any]])?.contains {
                        ($0["command"] as? String)?.contains("coucou") == true ||
                        ($0["command"] as? String)?.contains("NotchBuddy") == true
                    } ?? false
                }
                if matchers.isEmpty { hooks.removeValue(forKey: key) }
                else { hooks[key] = matchers }
            }
        }
        settings["hooks"] = hooks
        let newData = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try newData.write(to: settingsURL, options: .atomic)
    }

    private func buildHooksData(claudeURL: URL) throws -> Data {
        let settingsURL = claudeURL.appendingPathComponent("settings.json")
        var settings: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsURL),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings = parsed
        }
        let hookPath = Self.hookScriptPath
        let quotedCmd = "/bin/sh \"\(hookPath.replacingOccurrences(of: "\"", with: "\\\""))\""
        let events: [(String, Int)] = [
            ("SessionStart", 10), ("SessionEnd", 10),
            ("UserPromptSubmit", 10),
            ("PreToolUse", 10), ("PostToolUse", 10), ("PostToolUseFailure", 10),
            ("PermissionRequest", 10),
            ("Notification", 10),
            ("Stop", 10), ("StopFailure", 10),
            ("SubagentStart", 10), ("SubagentStop", 10),
        ]
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for (event, timeout) in events {
            var existing = hooks[event] as? [[String: Any]] ?? []
            existing.removeAll { ($0["hooks"] as? [[String: Any]])?.contains {
                ($0["command"] as? String)?.contains("coucou") == true ||
                ($0["command"] as? String)?.contains("NotchBuddy") == true
            } ?? false }
            existing.append(["hooks": [["type": "command", "command": quotedCmd, "timeout": timeout]]])
            hooks[event] = existing
        }
        settings["hooks"] = hooks
        return try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
    }
    #endif
}

/// A permission request whose nb-hook is waiting on the socket for the user's decision.
private struct PendingApproval {
    let token: UUID
    let fd: Int32
    let isCopilot: Bool
    let alwaysKey: String   // "<session>|<tool>" for Copilot's per-session "Always"
    let info: ApprovalInfo
    let projectName: String
    let cwd: String
    let payload: [String: Any]
}

// MARK: - Notification names for hook server → controller communication

extension Notification.Name {
    static let hookExpand = Notification.Name("notchBuddy.hookExpand")
}

// MARK: - nb-hook Python script content

private let nbHookScript = """
#!/usr/bin/env python3
# nb-hook — Notch Buddy hook relay for Claude Code
# Reads JSON from stdin, forwards to NotchBuddy via Unix socket, relays response.
import sys, json, os, socket, re

COPILOT_EVENT_NAMES = {
    'permissionRequest': 'PermissionRequest',
    'agentStop': 'Stop',
    'userPromptSubmitted': 'UserPromptSubmit',
    'errorOccurred': 'ErrorOccurred',
}

def normalize_copilot(payload):
    # The Copilot SDK sends some events (permissionRequest, subagentStart) in camelCase
    name = payload.get('hookName') or ''
    out = {re.sub(r'(?<!^)(?=[A-Z])', '_', k).lower(): v for k, v in payload.items()}
    out['hook_event_name'] = COPILOT_EVENT_NAMES.get(name, name[:1].upper() + name[1:])
    if 'tool_input' not in out and 'tool_args' in out:
        out['tool_input'] = out['tool_args']
    if isinstance(out.get('tool_input'), str):
        try:
            out['tool_input'] = json.loads(out['tool_input'])
        except Exception:
            pass
    return out

def last_assistant_line(path):
    # Best effort: VS Code and the Copilot SDK write JSONL transcripts with assistant.message events
    try:
        with open(path, 'rb') as f:
            f.seek(0, 2)
            f.seek(max(0, f.tell() - 512 * 1024))
            lines = f.read().decode('utf-8', 'ignore').splitlines()
        for line in reversed(lines):
            try:
                event = json.loads(line)
            except Exception:
                continue
            if event.get('type') != 'assistant.message':
                continue
            content = (event.get('data') or {}).get('content')
            if not isinstance(content, str):
                continue
            for text in content.splitlines():
                text = text.strip().lstrip('#>*-• ').replace('**', '').replace('`', '').strip()
                if text:
                    return text[:120]
    except Exception:
        pass
    return None

def main():
    if os.environ.get('NB_HOOK_DISABLE'):
        return
    try:
        raw = sys.stdin.buffer.read()
        if not raw:
            return
        payload = json.loads(raw)
    except Exception:
        return

    # Enrich with terminal context
    env = os.environ
    args = sys.argv[1:]
    agent = 'copilot' if '--copilot' in args else 'claude'
    if agent == 'copilot':
        if 'hook_event_name' not in payload and payload.get('hookName'):
            payload = normalize_copilot(payload)
        # The Copilot SDK (CLI, VS Code Agent Host) and VS Code's Local harness both load
        # every ~/.copilot/hooks/*.json: answer from one Coucou file per harness so events
        # aren't reported twice when both the CLI and VS Code hooks are installed.
        sdk_harness = bool(env.get('COPILOT_CLI'))
        vscode_entry = '--vscode' in args
        copilot_home = env.get('COPILOT_HOME') or os.path.expanduser('~/.copilot')
        cli_file = os.path.exists(os.path.join(copilot_home, 'hooks', 'coucou.json'))
        vscode_file = os.path.exists(os.path.expanduser('~/.copilot/hooks/coucou-vscode.json'))
        if sdk_harness and vscode_entry and cli_file:
            return
        if not sdk_harness and not vscode_entry and vscode_file:
            return
        if vscode_entry and not sdk_harness:
            payload['harness'] = 'vscode'
        if payload.get('hook_event_name') == 'Stop' and not payload.get('message'):
            summary = last_assistant_line(payload.get('transcript_path') or '')
            if summary:
                payload['message'] = summary
    payload['agent'] = agent
    payload.setdefault('term_program', env.get('TERM_PROGRAM', ''))
    payload.setdefault('iterm_session_id', env.get('ITERM_SESSION_ID', ''))
    payload.setdefault('term_session_id', env.get('TERM_SESSION_ID', ''))
    payload.setdefault('bundle_id', env.get('__CFBundleIdentifier', ''))
    payload.setdefault('ai_agent', env.get('AI_AGENT', ''))
    if 'cwd' not in payload or not payload['cwd']:
        payload['cwd'] = os.getcwd()

    event = payload.get('hook_event_name', '')
    socket_path = os.path.expanduser(
        '~/Library/Application Support/NotchBuddy/nb.sock'
    )

    if event == 'PreToolUse' and payload.get('harness') == 'vscode':
        # VS Code has no PermissionRequest: wait for the notch on PreToolUse.
        # The app answers right away unless the tool needs an approval.
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(0.5)
            s.connect(socket_path)
            s.sendall((json.dumps(payload) + '\\n').encode())
            s.settimeout(118)
            chunks = []
            while True:
                chunk = s.recv(4096)
                if not chunk:
                    break
                chunks.append(chunk)
                if b'\\n' in chunk:
                    break
            s.close()
            response = b''.join(chunks).decode().strip()
            decision = json.loads(response).get('permissionDecision') if response else None
            if decision in ('allow', 'deny', 'ask'):
                reasons = {
                    'allow': 'Approved from Coucou',
                    'deny': 'Denied from Coucou',
                    'ask': 'No answer in Coucou',
                }
                out = {'hookSpecificOutput': {
                    'hookEventName': 'PreToolUse',
                    'permissionDecision': decision,
                    'permissionDecisionReason': reasons[decision],
                }}
                sys.stdout.write(json.dumps(out) + '\\n')
                sys.stdout.flush()
        except Exception:
            pass
        # No output = VS Code keeps its normal confirmation flow
        sys.exit(0)

    if event == 'PermissionRequest':
        # Block and wait for NotchBuddy's decision (Claude Code allows up to 120s)
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(118)
            s.connect(socket_path)
            s.sendall((json.dumps(payload) + '\\n').encode())
            chunks = []
            while True:
                chunk = s.recv(4096)
                if not chunk:
                    break
                chunks.append(chunk)
                if b'\\n' in chunk:
                    break
            s.close()
            response = b''.join(chunks).decode().strip()
            if response and 'permissionDecision' in response:
                if agent == 'copilot':
                    decision = json.loads(response).get('permissionDecision')
                    if decision == 'allow':
                        out = {'behavior': 'allow'}
                    elif decision == 'deny':
                        out = {'behavior': 'deny', 'message': 'Denied from Coucou'}
                    else:
                        out = None
                    if out:
                        sys.stdout.write(json.dumps(out) + '\\n')
                        sys.stdout.flush()
                else:
                    sys.stdout.write(response + '\\n')
                    sys.stdout.flush()
        except Exception:
            pass
        # No output = no decision: the agent falls back to its own permission prompt
        sys.exit(0)

    # All other events: fire-and-forget (0.3s timeout, never blocks)
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(0.3)
        s.connect(socket_path)
        s.sendall((json.dumps(payload) + '\\n').encode())
        s.close()
    except Exception:
        pass  # Always exit cleanly — never block Claude Code

main()
sys.exit(0)
"""

// MARK: - nb-hook script for App Store (socket in sandboxed container)

private let nbHookScriptAppStore = """
#!/usr/bin/env python3
# nb-hook — Notch Buddy (App Store) hook relay for Claude Code
import sys, json, os, socket

def main():
    if os.environ.get('NB_HOOK_DISABLE'):
        return
    try:
        raw = sys.stdin.buffer.read()
        if not raw:
            return
        payload = json.loads(raw)
    except Exception:
        return

    env = os.environ
    payload.setdefault('term_program', env.get('TERM_PROGRAM', ''))
    payload.setdefault('iterm_session_id', env.get('ITERM_SESSION_ID', ''))
    payload.setdefault('term_session_id', env.get('TERM_SESSION_ID', ''))
    payload.setdefault('bundle_id', env.get('__CFBundleIdentifier', ''))
    if 'cwd' not in payload or not payload['cwd']:
        payload['cwd'] = os.getcwd()

    event = payload.get('hook_event_name', '')
    # App Store version: socket lives inside the sandboxed container
    socket_path = os.path.expanduser(
        '~/Library/Containers/fr.louisraille.Coucou/Data/Library/Application Support/NotchBuddy/nb.sock'
    )

    if event == 'PermissionRequest':
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(118)
            s.connect(socket_path)
            s.sendall((json.dumps(payload) + '\\n').encode())
            chunks = []
            while True:
                chunk = s.recv(4096)
                if not chunk:
                    break
                chunks.append(chunk)
                if b'\\n' in chunk:
                    break
            s.close()
            response = b''.join(chunks).decode().strip()
            if response and 'permissionDecision' in response:
                sys.stdout.write(response + '\\n')
                sys.stdout.flush()
                sys.exit(0)
        except Exception:
            pass
        sys.stdout.write('{"permissionDecision":"deny"}\\n')
        sys.stdout.flush()
        sys.exit(0)

    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(0.3)
        s.connect(socket_path)
        s.sendall((json.dumps(payload) + '\\n').encode())
        s.close()
    except Exception:
        pass

main()
sys.exit(0)
"""
