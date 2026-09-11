import Foundation

/// A token produced by ``HTMLTokenizer``.
public enum HTMLToken: Equatable {
    case text(String)
    case startTag(name: String, attributes: [String: String], selfClosing: Bool)
    case endTag(name: String)
}

/// A small, forgiving HTML tokenizer.
///
/// It understands comments, doctype/processing instructions, start and end
/// tags with quoted or unquoted attributes, raw-text elements (`script`,
/// `style`, …) and character references. It never throws: malformed markup
/// degrades to text.
public struct HTMLTokenizer {
    /// Elements whose content is not markup and is dropped entirely.
    static let rawTextElements: Set<String> = ["script", "style", "textarea", "template", "noscript"]

    public static func tokenize(_ html: String) -> [HTMLToken] {
        var tokenizer = HTMLTokenizer(bytes: Array(html.utf8))
        return tokenizer.run()
    }

    private let bytes: [UInt8]
    private var index = 0
    private var tokens: [HTMLToken] = []

    private init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    private mutating func run() -> [HTMLToken] {
        let count = bytes.count
        var textStart = 0

        while index < count {
            guard bytes[index] == UInt8(ascii: "<") else {
                index += 1
                continue
            }

            // Decide what kind of markup starts here; otherwise treat "<" as text.
            if startsWith("<!--") {
                flushText(from: textStart, to: index)
                if let end = find("-->", from: index + 4) {
                    index = end + 3
                } else {
                    index = count
                }
                textStart = index
            } else if startsWith("<!") || startsWith("<?") {
                flushText(from: textStart, to: index)
                if let end = findByte(UInt8(ascii: ">"), from: index) {
                    index = end + 1
                } else {
                    index = count
                }
                textStart = index
            } else if startsWith("</"), index + 2 < count, isNameStart(bytes[index + 2]) {
                flushText(from: textStart, to: index)
                index += 2
                let name = readName()
                if let end = findByte(UInt8(ascii: ">"), from: index) {
                    index = end + 1
                } else {
                    index = count
                }
                tokens.append(.endTag(name: name))
                textStart = index
            } else if index + 1 < count, isNameStart(bytes[index + 1]) {
                flushText(from: textStart, to: index)
                index += 1
                let name = readName()
                let (attributes, selfClosing) = readAttributes()
                tokens.append(.startTag(name: name, attributes: attributes, selfClosing: selfClosing))
                if !selfClosing, HTMLTokenizer.rawTextElements.contains(name) {
                    skipRawText(elementName: name)
                }
                textStart = index
            } else {
                index += 1
            }
        }
        flushText(from: textStart, to: count)
        return tokens
    }

    // MARK: - Helpers

    private func startsWith(_ literal: String) -> Bool {
        let lit = Array(literal.utf8)
        guard index + lit.count <= bytes.count else { return false }
        for (offset, byte) in lit.enumerated() where bytes[index + offset] != byte {
            return false
        }
        return true
    }

    private func find(_ literal: String, from start: Int) -> Int? {
        let lit = Array(literal.utf8)
        guard !lit.isEmpty, start >= 0 else { return nil }
        var i = start
        while i + lit.count <= bytes.count {
            if bytes[i] == lit[0] {
                var matched = true
                for (offset, byte) in lit.enumerated() where bytes[i + offset] != byte {
                    matched = false
                    break
                }
                if matched { return i }
            }
            i += 1
        }
        return nil
    }

    private func findByte(_ byte: UInt8, from start: Int) -> Int? {
        var i = start
        while i < bytes.count {
            if bytes[i] == byte { return i }
            i += 1
        }
        return nil
    }

    private func isNameStart(_ byte: UInt8) -> Bool {
        (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z")) || (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z"))
    }

    private func isNameByte(_ byte: UInt8) -> Bool {
        isNameStart(byte)
            || (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
            || byte == UInt8(ascii: "-") || byte == UInt8(ascii: "_") || byte == UInt8(ascii: ":")
    }

    private func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D || byte == 0x0C
    }

    private mutating func readName() -> String {
        let start = index
        while index < bytes.count, isNameByte(bytes[index]) {
            index += 1
        }
        return String(decoding: bytes[start..<index], as: UTF8.self).lowercased()
    }

    private mutating func skipWhitespace() {
        while index < bytes.count, isWhitespace(bytes[index]) {
            index += 1
        }
    }

    /// Reads attributes up to and including the closing ">".
    private mutating func readAttributes() -> ([String: String], Bool) {
        var attributes: [String: String] = [:]
        var selfClosing = false
        let count = bytes.count

        while index < count {
            skipWhitespace()
            guard index < count else { break }
            let byte = bytes[index]
            if byte == UInt8(ascii: ">") {
                index += 1
                return (attributes, selfClosing)
            }
            if byte == UInt8(ascii: "/") {
                index += 1
                if index < count, bytes[index] == UInt8(ascii: ">") {
                    index += 1
                    return (attributes, true)
                }
                selfClosing = false
                continue
            }

            // Attribute name: everything up to whitespace, "=", ">" or "/".
            let nameStart = index
            while index < count {
                let b = bytes[index]
                if isWhitespace(b) || b == UInt8(ascii: "=") || b == UInt8(ascii: ">") || (b == UInt8(ascii: "/") && index + 1 < count && bytes[index + 1] == UInt8(ascii: ">")) {
                    break
                }
                index += 1
            }
            if index == nameStart {
                // Unexpected byte; skip it to guarantee progress.
                index += 1
                continue
            }
            let name = String(decoding: bytes[nameStart..<index], as: UTF8.self).lowercased()

            skipWhitespace()
            var value = ""
            if index < count, bytes[index] == UInt8(ascii: "=") {
                index += 1
                skipWhitespace()
                if index < count, bytes[index] == UInt8(ascii: "\"") || bytes[index] == UInt8(ascii: "'") {
                    let quote = bytes[index]
                    index += 1
                    let valueStart = index
                    while index < count, bytes[index] != quote {
                        index += 1
                    }
                    value = String(decoding: bytes[valueStart..<index], as: UTF8.self)
                    if index < count { index += 1 }
                } else {
                    let valueStart = index
                    while index < count, !isWhitespace(bytes[index]), bytes[index] != UInt8(ascii: ">") {
                        index += 1
                    }
                    value = String(decoding: bytes[valueStart..<index], as: UTF8.self)
                }
            }
            if attributes[name] == nil {
                attributes[name] = HTMLEntities.decode(value)
            }
        }
        return (attributes, selfClosing)
    }

    /// Skips everything up to the matching end tag of a raw-text element.
    private mutating func skipRawText(elementName: String) {
        let closing = Array("</\(elementName)".utf8)
        var i = index
        while i + closing.count <= bytes.count {
            var matched = true
            for (offset, byte) in closing.enumerated() {
                let candidate = bytes[i + offset]
                let lower = (candidate >= UInt8(ascii: "A") && candidate <= UInt8(ascii: "Z")) ? candidate + 32 : candidate
                if lower != byte {
                    matched = false
                    break
                }
            }
            if matched {
                index = i + closing.count
                if let end = findByte(UInt8(ascii: ">"), from: index) {
                    index = end + 1
                } else {
                    index = bytes.count
                }
                tokens.append(.endTag(name: elementName))
                return
            }
            i += 1
        }
        index = bytes.count
    }

    private mutating func flushText(from start: Int, to end: Int) {
        guard end > start else { return }
        let raw = String(decoding: bytes[start..<end], as: UTF8.self)
        tokens.append(.text(HTMLEntities.decode(raw)))
    }
}

/// Decoding of HTML character references.
public enum HTMLEntities {
    static let named: [String: String] = {
        var table: [String: String] = [
            "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
            "hellip": "…", "mdash": "—", "ndash": "–", "lsquo": "‘", "rsquo": "’",
            "ldquo": "“", "rdquo": "”", "sbquo": "‚", "bdquo": "„", "bull": "•", "trade": "™",
            "larr": "←", "rarr": "→", "uarr": "↑", "darr": "↓", "harr": "↔",
            "euro": "€", "dagger": "†", "Dagger": "‡", "permil": "‰", "lsaquo": "‹", "rsaquo": "›",
            "ensp": "\u{2002}", "emsp": "\u{2003}", "thinsp": "\u{2009}", "zwnj": "\u{200C}", "zwj": "\u{200D}",
            "prime": "′", "Prime": "″", "oline": "‾", "frasl": "⁄", "minus": "−", "lowast": "∗",
            "infin": "∞", "ne": "≠", "le": "≤", "ge": "≥", "asymp": "≈", "equiv": "≡",
            "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ε", "lambda": "λ",
            "mu": "μ", "pi": "π", "sigma": "σ", "omega": "ω", "Omega": "Ω", "Delta": "Δ",
            "hearts": "♥", "spades": "♠", "clubs": "♣", "diams": "♦", "loz": "◊", "check": "✓",
            "OElig": "Œ", "oelig": "œ", "Scaron": "Š", "scaron": "š", "Yuml": "Ÿ", "fnof": "ƒ",
            "circ": "ˆ", "tilde": "˜", "nbsp": "\u{00A0}", "shy": "",
        ]
        // Latin-1 supplement, code points 161…255 in order.
        let latin1 = [
            "iexcl", "cent", "pound", "curren", "yen", "brvbar", "sect", "uml", "copy", "ordf", "laquo", "not", "shy", "reg", "macr",
            "deg", "plusmn", "sup2", "sup3", "acute", "micro", "para", "middot", "cedil", "sup1", "ordm", "raquo", "frac14", "frac12", "frac34", "iquest",
            "Agrave", "Aacute", "Acirc", "Atilde", "Auml", "Aring", "AElig", "Ccedil", "Egrave", "Eacute", "Ecirc", "Euml", "Igrave", "Iacute", "Icirc", "Iuml",
            "ETH", "Ntilde", "Ograve", "Oacute", "Ocirc", "Otilde", "Ouml", "times", "Oslash", "Ugrave", "Uacute", "Ucirc", "Uuml", "Yacute", "THORN", "szlig",
            "agrave", "aacute", "acirc", "atilde", "auml", "aring", "aelig", "ccedil", "egrave", "eacute", "ecirc", "euml", "igrave", "iacute", "icirc", "iuml",
            "eth", "ntilde", "ograve", "oacute", "ocirc", "otilde", "ouml", "divide", "oslash", "ugrave", "uacute", "ucirc", "uuml", "yacute", "thorn", "yuml",
        ]
        for (offset, name) in latin1.enumerated() where name != "shy" {
            table[name] = String(UnicodeScalar(UInt32(161 + offset))!)
        }
        return table
    }()

    /// Replaces character references (`&amp;`, `&#169;`, `&#x1F600;`) with their characters.
    public static func decode(_ input: String) -> String {
        guard input.contains("&") else { return input }
        var output = ""
        output.reserveCapacity(input.utf8.count)
        var iterator = input.makeIterator()
        var pending: [Character] = []

        func flushPending() {
            output.append(contentsOf: pending)
            pending.removeAll()
        }

        while let char = iterator.next() {
            guard char == "&" else {
                output.append(char)
                continue
            }
            // Collect up to 32 characters of a potential reference.
            var name = ""
            var terminated = false
            var lookahead: [Character] = []
            while let next = iterator.next() {
                if next == ";" {
                    terminated = true
                    break
                }
                if next.isLetter || next.isNumber || next == "#" {
                    name.append(next)
                    if name.count > 32 { break }
                } else {
                    lookahead.append(next)
                    break
                }
            }
            if terminated, let replacement = replacement(for: name) {
                output.append(replacement)
            } else if !terminated, !name.isEmpty, name.first != "#", let replacement = named[name], lookahead.first?.isLetter != true {
                // Legacy references without a trailing semicolon, e.g. "&copy 2020".
                output.append(replacement)
                pending = lookahead
                flushPending()
            } else {
                output.append("&")
                output.append(name)
                if terminated { output.append(";") }
                pending = lookahead
                flushPending()
            }
        }
        return output
    }

    private static func replacement(for name: String) -> String? {
        if name.hasPrefix("#") {
            let digits = name.dropFirst()
            let value: UInt32?
            if digits.first == "x" || digits.first == "X" {
                value = UInt32(digits.dropFirst(), radix: 16)
            } else {
                value = UInt32(digits, radix: 10)
            }
            guard let value, value != 0, let scalar = UnicodeScalar(value) else { return nil }
            return String(scalar)
        }
        return named[name]
    }
}
