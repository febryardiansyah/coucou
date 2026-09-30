import Foundation

// MARK: - Chat provider selection

enum ChatProvider: String, CaseIterable, Identifiable {
    case anthropic
    case openAICompatible
    case hermes

    var id: String { rawValue }

    var label: String {
        switch self {
        case .anthropic:        return "Anthropic (Claude)"
        case .openAICompatible: return "OpenAI-compatible endpoint"
        case .hermes:           return "Hermes (agent on your VPS)"
        }
    }

    var isConfigured: Bool {
        switch self {
        case .anthropic:        return KeychainStore.shared.get("anthropic-api-key") != nil
        case .openAICompatible: return !setting("openaiBaseURL").isEmpty && !setting("openaiModel").isEmpty
        case .hermes:           return !setting("hermesURL").isEmpty
        }
    }
}

private func setting(_ key: String) -> String {
    UserDefaults.standard.string(forKey: key) ?? ""
}

/// URL settings tolerate stray spaces and trailing slashes.
private func urlSetting(_ key: String) -> String {
    setting(key).trimmingCharacters(in: CharacterSet(charactersIn: " /"))
}

// MARK: - Non-Anthropic backends

extension ClaudeService {

    /// Plain-text transcript turns for backends that take simple role/content messages.
    /// `state.chatHistory` already contains the message being sent.
    private func transcript(context: PromptContext?, state: AppState) -> [(role: String, content: String)] {
        var turns = state.chatHistory.map { (role: $0.role == .user ? "user" : "assistant", content: $0.content) }
        if state.chatHistory.count == 1, let context, let first = turns.first {
            var prefix = ""
            switch context {
            case .window(let app, let title, let url):
                prefix = "Context — App: \(app), Window: \(title)" + (url.map { ", URL: \($0)" } ?? "")
            case .file(let name, let fileURL):
                prefix = "File: \(name)"
                if let fileURL, let data = try? Data(contentsOf: fileURL), data.count <= 200_000,
                   let text = String(data: data, encoding: .utf8) {
                    prefix += "\nFile contents:\n\(text)"
                }
            }
            turns[0] = (first.role, prefix + "\n\n" + first.content)
        }
        return turns
    }

    private func finishChat(_ text: String, state: AppState) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            showError("No response text.", state: state)
            return
        }
        state.chatHistory.append(ChatMessage(role: .assistant, content: trimmed))
        state.stateOverride = nil
        state.view = .prompt
        NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.happy)
    }

    /// POSTs a JSON body and returns the decoded JSON object (`[:]` if the body isn't a JSON object).
    /// Shows an error and returns nil on network or HTTP failure.
    private func postJSON(_ url: URL, body: [String: Any], headers: [String: String], timeout: TimeInterval,
                          errorPrefix: String, state: AppState) async -> [String: Any]? {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        request.timeoutInterval = timeout
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                let msg = String(data: data, encoding: .utf8) ?? "unknown error"
                showError("\(errorPrefix): \(String(msg.prefix(200)))", state: state)
                return nil
            }
            return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        } catch {
            showError("Network error: \(error.localizedDescription)", state: state)
            return nil
        }
    }

    // MARK: OpenAI-compatible (OpenRouter, Azure AI Foundry, Ollama, LM Studio, …)

    func chatOpenAICompatible(context: PromptContext?, state: AppState) async {
        let base = urlSetting("openaiBaseURL")
        let model = setting("openaiModel")
        guard !base.isEmpty, !model.isEmpty, let url = URL(string: base + "/chat/completions") else {
            showError("Set the endpoint URL and model in Settings.", state: state)
            return
        }

        var messages: [[String: String]] = [["role": "system", "content": systemPrompt]]
        messages += transcript(context: context, state: state).map { ["role": $0.role, "content": $0.content] }

        var headers: [String: String] = [:]
        if let key = KeychainStore.shared.get("openai-api-key"), !key.isEmpty {
            headers["Authorization"] = "Bearer \(key)"
        }

        guard let json = await postJSON(url, body: ["model": model, "messages": messages], headers: headers,
                                        timeout: 90, errorPrefix: "API error", state: state) else { return }
        guard let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let text = message["content"] as? String else {
            showError("Unexpected API response.", state: state)
            return
        }
        finishChat(text, state: state)
    }

    // MARK: Hermes (agent running on your VPS)

    /// Chats with the Hermes bridge (`POST {text, session}` -> `{reply}`).
    /// The bridge runs a real agent session on the VPS, so it keeps its own thread:
    /// only the newest user turn is sent, and the reply is appended to the notch chat.
    func chatHermes(context: PromptContext?, state: AppState) async {
        let raw = urlSetting("hermesURL")
        guard !raw.isEmpty, let url = URL(string: raw) else {
            showError("Set the Hermes bridge URL in Settings.", state: state)
            return
        }
        guard let query = state.chatHistory.last(where: { $0.role == .user })?.content,
              !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showError("Nothing to send.", state: state)
            return
        }

        let session = setting("hermesSession").isEmpty ? "coucou" : setting("hermesSession")
        var headers: [String: String] = [:]
        if let key = KeychainStore.shared.get("hermes-key"), !key.isEmpty {
            headers["X-Hermes-Key"] = key
        }

        guard let json = await postJSON(url, body: ["text": query, "session": session], headers: headers,
                                        timeout: 200, errorPrefix: "Hermes bridge", state: state) else { return }
        guard let text = json["reply"] as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showError("Empty reply from the Hermes bridge.", state: state)
            return
        }
        finishChat(text, state: state)
    }
}
