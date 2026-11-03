import Foundation

/// Turns shared text / links into a task or note title. Shared by the Share extension and the app.
enum ShareParsing {
    /// "#42" for a GitHub PR / issue, "ABC-118" for a Jira ticket: the server links tasks by
    /// these codes in the title (supabase/functions/_shared/links.ts).
    static func code(for url: URL) -> String? {
        guard let host = url.host()?.lowercased() else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        if host == "github.com" || host.hasSuffix(".github.com") {
            // owner / repo / pull|issues / 42
            guard parts.count >= 4, ["pull", "issues"].contains(parts[2]), let number = Int(parts[3]) else { return nil }
            return "#\(number)"
        }
        if host.hasSuffix("atlassian.net") || host.contains("jira") {
            let selected = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "selectedIssue" }?.value
            let candidate = selected ?? (parts.firstIndex(of: "browse").flatMap { parts.indices.contains($0 + 1) ? parts[$0 + 1] : nil })
            guard let key = candidate?.uppercased(), key.range(of: #"^[A-Z][A-Z0-9]+-\d+$"#, options: .regularExpression) != nil else { return nil }
            return key
        }
        return nil
    }

    /// First non-empty line of the shared text, else a readable form of the link; the PR / ticket
    /// code is added when the text does not already contain it.
    static func title(text: String?, url: URL?) -> String {
        let firstLine = (text ?? "")
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && $0 != url?.absoluteString }
        var title = firstLine ?? url.map(readable) ?? ""
        if title.count > 120 { title = String(title.prefix(117)) + "…" }
        if let url, let code = code(for: url), !title.localizedCaseInsensitiveContains(code) {
            title = title.isEmpty ? code : "\(title) (\(code))"
        }
        return title
    }

    /// PR / issue → "app-ios #42", ticket → "NOT-118", other links → "example.com/a/b".
    static func readable(_ url: URL) -> String {
        let parts = url.pathComponents.filter { $0 != "/" }
        if let code = code(for: url) {
            return code.hasPrefix("#") && parts.count >= 2 ? "\(parts[1]) \(code)" : code
        }
        let host = (url.host() ?? "").replacingOccurrences(of: "www.", with: "")
        return parts.isEmpty ? host : "\(host)/\(parts.joined(separator: "/"))"
    }
}
