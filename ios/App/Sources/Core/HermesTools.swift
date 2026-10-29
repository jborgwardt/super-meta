import Foundation
import RealtimeVoice

/// Direct `lab-exec` client and tool definitions for `https://exec.heil.haus`.
/// Allows Gemini Live to run code, shell commands, and read/write files directly on
/// allowlisted lab hosts (`vps`, `mac`, `panzer`, `pi`, `pihole`, `borgwardt`, `ha`)
/// without requiring Antigravity.
enum LabExecTools {
    static let defaultBaseURL = "https://exec.heil.haus"
    static let defaultToken = "lx_9nbhyvd4_UQGD6V3vExuU14O3LlA1Cm6sDHoL9oTkBLO0952KVxU"
    static let allowedHosts = ["vps", "mac", "panzer", "pi", "pihole", "borgwardt", "ha"]

    static let all: [RealtimeTool] = [exec, read, write, hosts]

    static let instructions = """
     You have direct access to `lab-exec` (https://exec.heil.haus) via `lab_exec`, `lab_read`, `lab_write`, and `lab_hosts` \
    to run code, Python/shell scripts, builds, and file operations directly on Justin's hosts: \
    `vps` (main VPS; for the desktop container use `incus exec --project apps desktop -- su - justin -c '...'`), \
    `mac` (Justin's MacBook Pro), `panzer`, `pi`, `pihole`, `borgwardt`, and `ha` (Home Assistant). \
    You can use `lab_exec`, `lab_read`, and `lab_write` directly to write and run code or shell commands immediately without needing Antigravity.
    """

    static let exec = RealtimeTool(
        name: "lab_exec",
        description: "Run a shell command or code directly on an allowlisted lab host (vps, mac, panzer, pi, pihole, borgwardt, ha) via lab-exec.",
        parametersJSON: """
        {"type":"object","properties":{\
        "host":{"type":"string","enum":["vps","mac","panzer","pi","pihole","borgwardt","ha"],"description":"Target lab host (default: vps)"},\
        "cmd":{"type":"string","description":"Shell command or script to execute"},\
        "timeout":{"type":"integer","description":"Timeout in seconds (1-120, default 30)"}},\
        "required":["host","cmd"]}
        """
    )

    static let read = RealtimeTool(
        name: "lab_read",
        description: "Read a text or code file from an allowlisted lab host (vps, mac, panzer, pi, pihole, borgwardt, ha) via lab-exec.",
        parametersJSON: """
        {"type":"object","properties":{\
        "host":{"type":"string","enum":["vps","mac","panzer","pi","pihole","borgwardt","ha"]},\
        "path":{"type":"string","description":"Absolute file path to read"}},\
        "required":["host","path"]}
        """
    )

    static let write = RealtimeTool(
        name: "lab_write",
        description: "Write a text or code file on an allowlisted lab host (vps, mac, panzer, pi, pihole, borgwardt, ha) via lab-exec.",
        parametersJSON: """
        {"type":"object","properties":{\
        "host":{"type":"string","enum":["vps","mac","panzer","pi","pihole","borgwardt","ha"]},\
        "path":{"type":"string","description":"Absolute file path to write"},\
        "content":{"type":"string","description":"Full file contents to write"}},\
        "required":["host","path","content"]}
        """
    )

    static let hosts = RealtimeTool(
        name: "lab_hosts",
        description: "List all allowlisted lab-exec hosts (vps, mac, panzer, pi, pihole, borgwardt, ha) and their connection details.",
        parametersJSON: #"{"type":"object","properties":{}}"#
    )

    @MainActor
    static func executeTool(name: String, args: [String: Any]) async -> [String: Any] {
        let token = KeychainStore.get("lab_exec_token").flatMap { $0.isEmpty ? nil : $0 } ?? defaultToken
        let baseURL = UserDefaults.standard.string(forKey: "lab_exec_url").flatMap { $0.isEmpty ? nil : $0 } ?? defaultBaseURL

        switch name {
        case "lab_hosts":
            return await request(url: "\(baseURL)/v1/hosts", method: "GET", token: token, body: nil, timeout: 15)
        case "lab_exec":
            let host = (args["host"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "vps"
            guard let cmd = args["cmd"] as? String, !cmd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return ["ok": false, "error": "Missing required parameter 'cmd'"]
            }
            let timeout = min(max((args["timeout"] as? Int) ?? 30, 1), 120)
            return await request(
                url: "\(baseURL)/v1/exec",
                method: "POST",
                token: token,
                body: ["host": host.isEmpty ? "vps" : host, "cmd": cmd, "timeout": timeout],
                timeout: TimeInterval(timeout + 5)
            )
        case "lab_read":
            let host = (args["host"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "vps"
            guard let path = args["path"] as? String, !path.isEmpty else {
                return ["ok": false, "error": "Missing required parameter 'path'"]
            }
            var comps = URLComponents(string: "\(baseURL)/v1/fs")
            comps?.queryItems = [
                URLQueryItem(name: "host", value: host.isEmpty ? "vps" : host),
                URLQueryItem(name: "path", value: path)
            ]
            guard let fullURL = comps?.url?.absoluteString else {
                return ["ok": false, "error": "Invalid lab_read URL"]
            }
            return await request(url: fullURL, method: "GET", token: token, body: nil, timeout: 30)
        case "lab_write":
            let host = (args["host"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "vps"
            guard let path = args["path"] as? String, !path.isEmpty,
                  let content = args["content"] as? String else {
                return ["ok": false, "error": "Missing required parameter 'path' or 'content'"]
            }
            return await request(
                url: "\(baseURL)/v1/fs",
                method: "POST",
                token: token,
                body: ["host": host.isEmpty ? "vps" : host, "path": path, "content": content],
                timeout: 30
            )
        default:
            return ["ok": false, "error": "Unknown lab-exec tool \(name)"]
        }
    }

    @MainActor
    private static func request(
        url: String,
        method: String,
        token: String,
        body: [String: Any]?,
        timeout: TimeInterval
    ) async -> [String: Any] {
        guard let requestURL = URL(string: url) else {
            return ["ok": false, "error": "Invalid URL \(url)"]
        }
        var req = URLRequest(url: requestURL)
        req.httpMethod = method
        req.timeoutInterval = timeout
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            if var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                if let stdout = obj["stdout"] as? String, stdout.count > 4000 {
                    obj["stdout"] = String(stdout.prefix(4000)) + "\n...[truncated]"
                }
                if let content = obj["content"] as? String, content.count > 4000 {
                    obj["content"] = String(content.prefix(4000)) + "\n...[truncated]"
                }
                return obj
            }
            let raw = String(data: data, encoding: .utf8) ?? ""
            return ["ok": true, "output": String(raw.prefix(4000))]
        } catch {
            return ["ok": false, "error": error.localizedDescription]
        }
    }
}

/// Realtime tool definitions that let Gemini Live command `lab-exec` directly and/or
/// optionally hand off to the user's remote Antigravity coding instances (`desktop-void-mars`,
/// `justins-macbook-pro-local-solar-axis`, and `VPS (100.64.0.18)`). Dispatched by `HermesService.handleToolCall`.
enum HermesTools {
    static let antigravityTools: [RealtimeTool] = [execute, ask, spawnTask, sendMessage, sessionsStatus, switchInstance]
    static var all: [RealtimeTool] { LabExecTools.all + antigravityTools }

    static func activeTools(antigravityEnabled: Bool) -> [RealtimeTool] {
        antigravityEnabled ? (LabExecTools.all + antigravityTools) : LabExecTools.all
    }

    /// Appended to the session instructions when the Antigravity Bridge is configured.
    static var instructionsAddendum: String {
        instructionsAddendum(for: .desktopVoidMars, antigravityEnabled: true)
    }

    static func instructionsAddendum(for instance: AntigravityInstance, antigravityEnabled: Bool = true) -> String {
        if !antigravityEnabled {
            return LabExecTools.instructions + """
             Antigravity IDE handoff is currently turned off (optional). Run all code, scripts, file edits, and shell commands \
            directly using `lab_exec`, `lab_read`, and `lab_write` on the appropriate host (`vps`, `mac`, `panzer`, `pi`, `ha`, or `borgwardt`) \
            and speak a concise summary of the result back to the user.
            """
        }
        return LabExecTools.instructions + """
         In addition to direct `lab_exec`, you also have optional access to the user's remote Antigravity coding agent \
        (currently targeting \(instance.title) — \(instance.subtitle)) via `antigravity_spawn_task`, `antigravity_execute`, \
        `antigravity_ask`, `antigravity_switch_instance`, `antigravity_send_message`, and `antigravity_sessions_status`. \
        When the user asks to run a quick command, script, or file check, or says to use `lab_exec`, call `lab_exec` / `lab_read` / `lab_write` directly. \
        When the user specifically asks for Antigravity or dispatches a larger coding job to Antigravity, call `antigravity_spawn_task` or `antigravity_execute`.
        """
    }

    static let execute = RealtimeTool(
        name: "antigravity_execute",
        description: "Send a coding job, command, or task to the remote Antigravity coding agent (defaults to desktop-void-mars). Use for coding tasks, repository edits, running scripts, or any work on Antigravity.",
        parametersJSON: """
        {"type":"object","properties":{\
        "task":{"type":"string","description":"Complete, specific description of what Antigravity should do"}},\
        "required":["task"]}
        """
    )

    static let unavailableInstructions = """
    Antigravity is currently offline or not paired with this phone. Do not claim you
    can send work to Antigravity, access its connected services, or wait for an
    Antigravity reply. Explain briefly that the Antigravity connection must be restored
    in the app before those actions are available.
    """

    static let ask = RealtimeTool(
        name: "antigravity_ask",
        description: "Ask the user's remote Antigravity coding agent a question or give it a coding instruction, and get its reply.",
        parametersJSON: """
        {"type":"object","properties":{\
        "question":{"type":"string","description":"The question or coding instruction for Antigravity"},\
        "session_id":{"type":"string","description":"Optional session key to target; omit for the active session"}},\
        "required":["question"]}
        """
    )

    static let spawnTask = RealtimeTool(
        name: "antigravity_spawn_task",
        description: "Submit a background coding job to the user's remote Antigravity instance (defaults to desktop-void-mars). When the job finishes, a short report will be spoken back to the user.",
        parametersJSON: """
        {"type":"object","properties":{\
        "prompt":{"type":"string","description":"What the coding job should accomplish on Antigravity"},\
        "repo":{"type":"string","description":"Optional repository name or workspace path"}},\
        "required":["prompt"]}
        """
    )

    static let sendMessage = RealtimeTool(
        name: "antigravity_send_message",
        description: "Send a message to someone through one of the agent's channels (telegram, whatsapp, discord, slack). Confirm recipient and content with the user first.",
        parametersJSON: """
        {"type":"object","properties":{\
        "channel":{"type":"string","enum":["telegram","whatsapp","discord","slack"]},\
        "recipient":{"type":"string","description":"Chat id, phone number, or @username"},\
        "message":{"type":"string"}},\
        "required":["channel","recipient","message"]}
        """
    )

    static let sessionsStatus = RealtimeTool(
        name: "antigravity_sessions_status",
        description: "List the active Antigravity instance's sessions and what each is doing — use when the user asks what Antigravity is working on or a task's status.",
        parametersJSON: #"{"type":"object","properties":{}}"#
    )

    static let switchInstance = RealtimeTool(
        name: "antigravity_switch_instance",
        description: "Switch the active remote Antigravity target instance between desktop-void-mars, justins-macbook-pro-local-solar-axis, and vps-cli.",
        parametersJSON: """
        {"type":"object","properties":{\
        "instance":{"type":"string","enum":["desktop-void-mars","justins-macbook-pro-local-solar-axis","vps-cli"],"description":"Remote Antigravity instance to target"}},\
        "required":["instance"]}
        """
    )
}
