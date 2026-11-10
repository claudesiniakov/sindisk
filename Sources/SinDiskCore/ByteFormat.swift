import Foundation

/// Размеры в десятичных единицах, как в Finder (1 ГБ = 10⁹ байт).
public enum ByteFormat {
    public static func string(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Разбор строк вида `500MB`, `1.5GB`, `10k`, `2 ГБ`.
    public static func parse(_ raw: String) -> Int64? {
        let s = raw.lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: ",", with: ".")
        guard !s.isEmpty else { return nil }
        var numberPart = ""
        var unitPart = ""
        for ch in s {
            if unitPart.isEmpty, ch.isNumber || ch == "." {
                numberPart.append(ch)
            } else {
                unitPart.append(ch)
            }
        }
        guard let value = Double(numberPart) else { return nil }
        let multiplier: Double
        switch unitPart {
        case "", "b", "б", "byte", "bytes": multiplier = 1
        case "k", "kb", "к", "кб": multiplier = 1e3
        case "m", "mb", "м", "мб": multiplier = 1e6
        case "g", "gb", "г", "гб": multiplier = 1e9
        case "t", "tb", "т", "тб": multiplier = 1e12
        default: return nil
        }
        return Int64(value * multiplier)
    }
}
