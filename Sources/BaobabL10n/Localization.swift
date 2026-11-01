import Foundation

// Traduction de l'interface, partagée par DiskUsageKit, UpdateKit et l'app iBaobab (même mécanisme qu'iExplorer).
// Les textes sont cherchés dans le Localizable.strings de l'app hôte : iBaobab ou iExplorer fournit les traductions.

/// Texte d'interface écrit en français dans le code, traduit d'après `<langue>.lproj/Localizable.strings`.
/// Chaque interpolation devient « %@ » dans la clé (« \(n) éléments » → « %@ éléments ») ; la traduction
/// peut réordonner les valeurs avec « %1$@ », « %2$@ »…
public struct LocalizedText: ExpressibleByStringInterpolation {
    public var key = ""
    public var arguments: [String] = []

    public init(stringLiteral value: String) {
        key = value.replacingOccurrences(of: "%", with: "%%")
    }

    public init(stringInterpolation: Interpolation) {
        key = stringInterpolation.key
        arguments = stringInterpolation.arguments
    }

    public struct Interpolation: StringInterpolationProtocol {
        var key = ""
        var arguments: [String] = []

        public init(literalCapacity: Int, interpolationCount: Int) {}

        public mutating func appendLiteral(_ literal: String) {
            key += literal.replacingOccurrences(of: "%", with: "%%")
        }

        public mutating func appendInterpolation<T>(_ value: T) {
            key += "%@"
            arguments.append("\(value)")
        }
    }
}

/// Texte traduit dans la langue de l'interface (voir `LocalizedText`).
public func L(_ text: LocalizedText) -> String {
    let template = Bundle.main.localizedString(forKey: text.key, value: text.key, table: nil)
    var result = ""
    var index = 0
    var characters = template[...]
    while let percent = characters.firstIndex(of: "%") {
        result += characters[..<percent]
        let rest = characters[characters.index(after: percent)...]
        if rest.hasPrefix("%") {
            result += "%"
            characters = rest.dropFirst()
        } else if rest.hasPrefix("@") {
            result += index < text.arguments.count ? text.arguments[index] : ""
            index += 1
            characters = rest.dropFirst()
        } else if let dollar = rest.firstIndex(of: "$"), let position = Int(rest[..<dollar]),
                  rest[rest.index(after: dollar)...].hasPrefix("@") {
            result += position - 1 < text.arguments.count && position > 0 ? text.arguments[position - 1] : ""
            characters = rest[rest.index(dollar, offsetBy: 2)...]
        } else {
            result += "%"
            characters = rest
        }
    }
    return result + characters
}
