enum MenuItemTitleFormatter {
    private static let maximumCharacterCount = 30

    static func string(from value: String) -> String {
        let singleLineValue = value
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")

        guard singleLineValue.count > maximumCharacterCount else {
            return singleLineValue
        }

        return String(singleLineValue.prefix(maximumCharacterCount - 1)) + "…"
    }
}
