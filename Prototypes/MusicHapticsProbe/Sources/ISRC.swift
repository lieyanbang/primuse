import Foundation

enum ISRC {
    static func normalized(_ value: String) -> String? {
        let code = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()

        guard code.range(of: #"^[A-Z]{2}[A-Z0-9]{3}[0-9]{7}$"#, options: .regularExpression) != nil else {
            return nil
        }

        return code
    }
}
