import Foundation

/// 命令速查、配方和总搜索共用：先精确包含，短词不模糊，长词允许 1 个字母误差。
public enum TextSearch {
    public static func matches(_ haystack: String, needle: String) -> Bool {
        let hay = normalize(haystack)
        let key = normalize(needle)
        guard !key.isEmpty else { return true }
        if allowsSubstring(key), hay.contains(key) { return true }

        let tokens = key.split { $0.isWhitespace || "/,;|".contains($0) }.map(String.init)
        guard !tokens.isEmpty else { return true }
        return tokens.allSatisfy { tokenMatches(hay, $0) }
    }

    public static func editDistance(_ lhs: String, _ rhs: String) -> Int {
        if lhs == rhs { return 0 }
        if lhs.isEmpty { return rhs.count }
        if rhs.isEmpty { return lhs.count }
        if abs(lhs.count - rhs.count) > 1 { return 2 }

        let left = Array(lhs)
        let right = Array(rhs)
        var previous = Array(0...right.count)
        var current = Array(repeating: 0, count: right.count + 1)

        for i in 1...left.count {
            current[0] = i
            for j in 1...right.count {
                let cost = left[i - 1] == right[j - 1] ? 0 : 1
                current[j] = min(
                    previous[j] + 1,
                    current[j - 1] + 1,
                    previous[j - 1] + cost
                )
            }
            swap(&previous, &current)
        }
        return previous[right.count]
    }

    private static func tokenMatches(_ haystack: String, _ token: String) -> Bool {
        guard !token.isEmpty else { return true }
        let words = haystack.split { !($0.isLetter || $0.isNumber) }.map(String.init)
        // 拉丁短词只按整词比，避免 `dd` 命中 `add`；中文一两字仍按包含。
        if !allowsSubstring(token) {
            return words.contains(token)
        }
        if haystack.contains(token) { return true }
        guard token.count >= 4 else { return false }
        return words.contains { word in
            guard abs(word.count - token.count) <= 1 else { return false }
            return editDistance(word, token) <= 1
        }
    }

    private static func allowsSubstring(_ token: String) -> Bool {
        token.count >= 3 || token.unicodeScalars.contains { scalar in
            (0x3400...0x9FFF).contains(scalar.value) || (0x3040...0x30FF).contains(scalar.value)
        }
    }

    private static func normalize(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
    }
}
