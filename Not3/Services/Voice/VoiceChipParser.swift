import Foundation

/// Turns a Vietnamese sentence into chip values.
/// "Chiều nay lúc 3 giờ rưỡi học tiếng Anh 25 phút" → title "Học tiếng Anh", 15:30, 25 phút.
struct VoiceParse: Equatable, Sendable {
    var title: String
    var durationMinutes: Int?
    var hour: Int?
    var minute: Int?
}

enum VoiceChipParser {
    static func parse(_ text: String) -> VoiceParse {
        // Keep the user's casing ("tiếng Anh"); all patterns are case-insensitive.
        var working = " " + text + " "
        let lower = text.lowercased()
        var duration: Int?
        var hour: Int?
        var minute: Int?

        // Duration: "25 phút", "45p", "1 tiếng", "nửa tiếng", "1 tiếng rưỡi".
        if let match = firstMatch(#"(\d{1,2})\s*(tiếng|giờ đồng hồ)(\s*rưỡi)?"#, in: working) {
            duration = (Int(match.groups[0]) ?? 0) * 60 + (match.groups[2].isEmpty ? 0 : 30)
            working = match.removed
        } else if let match = firstMatch(#"nửa tiếng"#, in: working) {
            duration = 30
            working = match.removed
        }
        if duration == nil, let match = firstMatch(#"(\d{1,3})\s*(phút|p)(?=\W)"#, in: working) {
            duration = Int(match.groups[0])
            working = match.removed
        }

        // Time: "lúc 3 giờ", "15h30", "3:30", "3 giờ rưỡi", "lúc 9 giờ tối".
        var period = ""
        if let match = firstMatch(
            #"(lúc\s*)?(\d{1,2})\s*(?:giờ|h(?=[\d\W])|:)\s*(\d{1,2})?(\s*rưỡi)?(\s*phút)?(\s*(?:sáng|trưa|chiều|tối))?"#,
            in: working
        ) {
            hour = Int(match.groups[1])
            minute = match.groups[3].isEmpty ? (Int(match.groups[2]) ?? 0) : 30
            period = match.groups[5].lowercased()
            working = match.removed
        }
        let isAfternoon = ["chiều", "tối"].contains { period.contains($0) }
            || ["chiều nay", "tối nay", "buổi chiều", "buổi tối"].contains { lower.contains($0) }
        if let h = hour, h < 12, isAfternoon {
            hour = h + 12
        }

        // Drop filler words so what is left is the task.
        let fillers = [
            "chiều nay", "tối nay", "sáng mai", "chiều mai", "hôm nay",
            "mình sẽ", "tôi sẽ", "em sẽ", "sẽ", "trong vòng", "trong", "khoảng", "lúc",
        ]
        for filler in fillers {
            working = working.replacingOccurrences(of: " \(filler) ", with: " ", options: .caseInsensitive)
        }
        let title = working
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .capitalizedFirst

        if let h = hour, !(0...23).contains(h) { hour = nil; minute = nil }
        if let m = minute, !(0...59).contains(m) { minute = 0 }
        return VoiceParse(title: title, durationMinutes: duration, hour: hour, minute: minute)
    }

    private struct Match {
        let groups: [String]
        let removed: String
    }

    private static func firstMatch(_ pattern: String, in text: String) -> Match? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = text as NSString
        guard let result = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let groups = (1..<result.numberOfRanges).map { index -> String in
            let range = result.range(at: index)
            return range.location == NSNotFound ? "" : ns.substring(with: range)
        }
        return Match(groups: groups, removed: ns.replacingCharacters(in: result.range, with: " "))
    }
}
