import Foundation

/// Ett talat kommando som ersätts med tecken eller text, t.ex. "utropstecken" → "!" och "ny rad" → radbrytning.
struct VoiceCommand: Identifiable, Equatable {
    enum Kind: Equatable {
        /// Fäster mot föregående ord: "hej utropstecken" → "hej!"
        case attachLeft
        /// Fäster mot nästa ord: "öppna parentes" → "(text"
        case attachRight
        /// Utan mellanslag på båda sidor: "och snedstreck eller" → "och/eller"
        case attachBoth
        /// Radbrytning(ar); nästa ord får stor bokstav.
        case newline
        /// Citattecken: växlar mellan att öppna och stänga.
        case quote
        /// Fristående text med mellanslag runt, t.ex. "mvh" → "Med vänliga hälsningar".
        case text
    }

    var id: String
    var phrases: [String]
    var replacement: String
    var kind: Kind
    /// Ersätt inte om föregående ord är något av dessa (t.ex. "ska komma").
    var notAfter: Set<String> = []
    /// Ersätt inte om nästa ord är något av dessa (t.ex. "komma ihåg").
    var notBefore: Set<String> = []
    /// Ersätt inte om nästa ord är ett tal (t.ex. "punkt 3").
    var notBeforeNumber = false

    var displayReplacement: String {
        replacement.replacingOccurrences(of: "\n", with: "↵")
    }
}

extension VoiceCommand {
    private static let modalVerbs: Set<String> = [
        "ska", "skall", "att", "kan", "vill", "ville", "måste", "skulle", "kunde", "kunna", "får", "fick", "fått",
        "bör", "borde", "lär", "tänker", "brukar", "börjar", "behöver", "hinner", "hann", "försöker", "lyckas",
        "lyckades", "verkar", "tycks", "slipper", "vågar", "orkar", "hoppas", "kommer", "råkar", "inte", "aldrig",
        "också", "nog", "ju", "väl", "snart", "gärna", "redan", "nu", "då", "sen", "sedan", "kanske", "alltid",
    ]
    private static let kommaParticles: Set<String> = [
        "ihåg", "överens", "hem", "in", "ut", "fram", "till", "åt", "bort", "tillbaka", "igång", "undan", "över",
        "förbi", "loss", "tillrätta", "ifråga", "upp", "ner", "dit", "hit", "på", "med", "av", "efter", "före",
        "nära", "hemifrån", "iväg", "dit", "härifrån", "därifrån", "underfund", "åt",
    ]
    private static let determiners: Set<String> = [
        "en", "ett", "den", "det", "denna", "detta", "varje", "någon", "något", "viss", "visst", "samma",
        "första", "andra", "tredje", "sista", "nästa", "vid", "per", "viktig", "viktigaste", "enda", "ny",
    ]

    /// Inbyggda svenska kommandon.
    static let builtIn: [VoiceCommand] = [
        VoiceCommand(id: "newline", phrases: ["ny rad", "nyrad", "radbrytning"], replacement: "\n", kind: .newline,
                     notAfter: determiners),
        VoiceCommand(id: "paragraph", phrases: ["nytt stycke", "ny paragraf"], replacement: "\n\n", kind: .newline,
                     notAfter: determiners),
        VoiceCommand(id: "period", phrases: ["punkt"], replacement: ".", kind: .attachLeft,
                     notAfter: determiners, notBeforeNumber: true),
        VoiceCommand(id: "comma", phrases: ["komma", "kommatecken"], replacement: ",", kind: .attachLeft,
                     notAfter: modalVerbs, notBefore: kommaParticles),
        // Inkluderar vanliga felhörningar från modellen (inga riktiga ord, så de kan inte förväxlas).
        VoiceCommand(id: "exclamation", phrases: ["utropstecken", "utrotstecken", "utrottecken", "utropsteckan"],
                     replacement: "!", kind: .attachLeft),
        VoiceCommand(id: "question", phrases: ["frågetecken"], replacement: "?", kind: .attachLeft),
        VoiceCommand(id: "colon", phrases: ["kolon"], replacement: ":", kind: .attachLeft),
        VoiceCommand(id: "semicolon", phrases: ["semikolon"], replacement: ";", kind: .attachLeft),
        VoiceCommand(id: "ellipsis", phrases: ["tre punkter", "punkt punkt punkt"], replacement: "…", kind: .attachLeft),
        VoiceCommand(id: "dash", phrases: ["tankstreck"], replacement: "–", kind: .text),
        VoiceCommand(id: "hyphen", phrases: ["bindestreck"], replacement: "-", kind: .attachBoth),
        VoiceCommand(id: "slash", phrases: ["snedstreck"], replacement: "/", kind: .attachBoth),
        VoiceCommand(id: "openParen", phrases: ["öppna parentes", "vänsterparentes", "start parentes", "parentes start"],
                     replacement: "(", kind: .attachRight),
        VoiceCommand(id: "closeParen", phrases: ["stäng parentes", "högerparentes", "slut parentes", "parentes slut"],
                     replacement: ")", kind: .attachLeft),
        VoiceCommand(id: "quote", phrases: ["citattecken"], replacement: "”", kind: .quote),
        VoiceCommand(id: "at", phrases: ["snabel-a", "snabel a"], replacement: "@", kind: .attachBoth),
    ]

    /// Tolkar användarens egna kommandon, en per rad: `fras = ersättning`. `\n` i ersättningen ger ny rad.
    /// Flera fraser kan anges med `|`, t.ex. `utrotstecken | utropsteckan = !`.
    static func parseCustom(_ text: String) -> [VoiceCommand] {
        text.split(whereSeparator: \.isNewline).enumerated().compactMap { index, line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), let eq = trimmed.firstIndex(of: "=") else { return nil }
            let phrases = trimmed[..<eq].split(separator: "|")
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let replacement = String(trimmed[trimmed.index(after: eq)...])
                .trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\t", with: "\t")
            guard !phrases.isEmpty, !replacement.isEmpty else { return nil }
            return VoiceCommand(id: "custom-\(index)", phrases: phrases, replacement: replacement,
                                kind: inferKind(replacement))
        }
    }

    private static func inferKind(_ replacement: String) -> Kind {
        if replacement.allSatisfy(\.isNewline) { return .newline }
        if replacement.allSatisfy({ ".,!?:;…)]}%".contains($0) }) { return .attachLeft }
        if replacement.allSatisfy({ "([{".contains($0) }) { return .attachRight }
        if replacement.allSatisfy({ "/@-_".contains($0) }) { return .attachBoth }
        return .text
    }
}

/// Ersätter talade kommandon i en transkribering och städar mellanslag och versaler runt dem.
/// Taligenkänningsmodeller sätter ofta egna skiljetecken runt kommandoordet ("Hej, utropstecken."),
/// så sådana skiljetecken intill kommandot tas bort.
struct VoiceCommandProcessor {
    private let regex: NSRegularExpression?
    private let lookup: [String: VoiceCommand]

    private static let modelPunctuation = ",.;:!?…"
    private static let sentenceEnders = ".!?…"

    init(commands: [VoiceCommand]) {
        var lookup: [String: VoiceCommand] = [:]
        var patterns: [(String, Int)] = []
        for command in commands {
            for phrase in command.phrases {
                let words = Self.words(phrase)
                guard !words.isEmpty else { continue }
                lookup[words.joined(separator: " ")] = command  // senare (egna) kommandon vinner
                let pattern = words.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "[\\s\\-]+")
                patterns.append((pattern, phrase.count))
            }
        }
        self.lookup = lookup
        guard !patterns.isEmpty else { regex = nil; return }
        // Längsta fraser först så att "punkt punkt punkt" vinner över "punkt".
        let alternation = patterns.sorted { $0.1 > $1.1 }.map(\.0).joined(separator: "|")
        let p = Self.escapedClass(Self.modelPunctuation)
        let full = "(\\s*)([\(p)]*)\\s*(?<![\\p{L}\\p{N}])(\(alternation))(?![\\p{L}\\p{N}])([\(p)]*)"
        regex = try? NSRegularExpression(pattern: full, options: [.caseInsensitive])
    }

    func process(_ text: String) -> String {
        guard let regex else { return text }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }

        var out = ""
        var cursor = 0
        var afterCommand = false
        var needSpace = false
        var caseMode: CaseMode = .keep
        var quoteOpen = false

        func appendSegment(_ segment: String) {
            var seg = segment
            if afterCommand {
                seg = String(seg.drop(while: { $0 == " " || $0 == "\t" }))
                guard let first = seg.first else { return }
                if needSpace && (first.isLetter || first.isNumber || "(\"”'«[".contains(first)) {
                    out += " "
                }
                seg = caseMode.apply(to: seg)
                afterCommand = false
            }
            out += seg
        }

        func trimTrailingSpaces() {
            while let last = out.last, last == " " || last == "\t" { out.removeLast() }
        }

        for match in matches {
            let whole = match.range
            let prefixPunct = ns.substring(with: match.range(at: 2))
            let phrase = ns.substring(with: match.range(at: 3))
            let suffixPunct = ns.substring(with: match.range(at: 4))
            let before = ns.substring(with: NSRange(location: cursor, length: whole.location - cursor))

            let nextWord = Self.firstWord(in: ns.substring(from: NSMaxRange(whole)))
            guard let command = lookup[Self.words(phrase).joined(separator: " ")],
                  allowed(command, previous: Self.lastWord(in: ns.substring(to: whole.location)), next: nextWord) else {
                // Inte ett kommando här – behåll texten som den är.
                appendSegment(before + ns.substring(with: whole))
                cursor = NSMaxRange(whole)
                continue
            }

            appendSegment(before)
            cursor = NSMaxRange(whole)
            let removedSentenceEnd = (prefixPunct + suffixPunct).contains { Self.sentenceEnders.contains($0) }

            switch command.kind {
            case .attachLeft:
                trimTrailingSpaces()
                // Inuti e-post/webbadresser ("erik snabel-a knowit punkt se") ska punkten inte avsluta en mening.
                // Modellen skriver nästa ord med stor bokstav om den tror att en ny mening börjar.
                let currentToken = String(out.reversed().prefix(while: { !$0.isWhitespace }).reversed()).lowercased()
                let inAddress = currentToken.contains(where: { $0 == "@" || $0 == "/" }) || currentToken.hasPrefix("www")
                if command.replacement == ".", inAddress, let nextWord, nextWord.first?.isLowercase == true {
                    out += "."
                    needSpace = false
                    caseMode = .lower
                    afterCommand = true
                    continue
                }
                out += command.replacement
                needSpace = true
                if command.replacement.contains(where: { Self.sentenceEnders.contains($0) }) {
                    caseMode = .upper
                } else {
                    caseMode = removedSentenceEnd ? .lower : .keep
                }
            case .attachRight:
                trimTrailingSpaces()
                if let last = out.last, !last.isWhitespace { out += " " }
                out += command.replacement
                needSpace = false
                caseMode = removedSentenceEnd ? .lower : .keep
            case .attachBoth:
                trimTrailingSpaces()
                out += command.replacement
                needSpace = false
                caseMode = .keep
            case .newline:
                trimTrailingSpaces()
                // Behåll modellens punkt/frågetecken före radbrytningen, men inte kommatecken.
                out += prefixPunct.filter { Self.sentenceEnders.contains($0) }
                out += command.replacement
                needSpace = false
                caseMode = .upper
            case .quote:
                trimTrailingSpaces()
                if quoteOpen {
                    out += command.replacement
                    needSpace = true
                } else {
                    if let last = out.last, !last.isWhitespace { out += " " }
                    out += command.replacement
                    needSpace = false
                }
                quoteOpen.toggle()
                caseMode = .keep
            case .text:
                trimTrailingSpaces()
                out += prefixPunct
                if let last = out.last, !last.isWhitespace { out += " " }
                out += command.replacement + suffixPunct
                needSpace = true
                caseMode = suffixPunct.contains { Self.sentenceEnders.contains($0) } ? .upper : .keep
            }
            afterCommand = true
        }
        appendSegment(ns.substring(from: cursor))

        // Inga mellanslag i början av rader.
        return out.replacingOccurrences(of: "\n[ \t]+", with: "\n", options: .regularExpression)
    }

    private func allowed(_ command: VoiceCommand, previous: String?, next: String?) -> Bool {
        if let previous, command.notAfter.contains(previous.lowercased()) { return false }
        if let next {
            if command.notBefore.contains(next.lowercased()) { return false }
            if command.notBeforeNumber, next.first?.isNumber == true { return false }
        }
        return true
    }

    // MARK: Hjälpfunktioner

    private enum CaseMode {
        case keep, upper, lower

        func apply(to s: String) -> String {
            guard let i = s.firstIndex(where: \.isLetter) else { return s }
            // Ändra bara om bokstaven står först i segmentet (efter ev. citattecken/parentes).
            guard s[s.startIndex..<i].allSatisfy({ "(\"”'«[".contains($0) }) else { return s }
            switch self {
            case .keep:
                return s
            case .upper:
                return s.replacingCharacters(in: i...i, with: s[i].uppercased())
            case .lower:
                // Rör inte förkortningar som "EU" eller "AI".
                let word = s[i...].prefix(while: \.isLetter)
                guard word.dropFirst().allSatisfy({ $0.isLowercase }) else { return s }
                return s.replacingCharacters(in: i...i, with: s[i].lowercased())
            }
        }
    }

    private static func words(_ s: String) -> [String] {
        s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    private static func lastWord(in s: String) -> String? {
        let trimmed = s.reversed().drop(while: { !$0.isLetter && !$0.isNumber })
        let word = String(trimmed.prefix(while: { $0.isLetter || $0.isNumber }).reversed())
        return word.isEmpty ? nil : word
    }

    private static func firstWord(in s: String) -> String? {
        let trimmed = s.drop(while: { !$0.isLetter && !$0.isNumber })
        let word = String(trimmed.prefix(while: { $0.isLetter || $0.isNumber }))
        return word.isEmpty ? nil : word
    }

    private static func escapedClass(_ chars: String) -> String {
        chars.map { "\\-[]^".contains($0) ? "\\\($0)" : String($0) }.joined()
    }
}
