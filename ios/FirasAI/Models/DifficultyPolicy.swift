import Foundation

nonisolated struct DifficultyCalibration: Codable, Equatable, Sendable {
    let level: Int
    let previous: Int?
    let direction: Int
    let magnitude: Int
    let clamp: String?
    init(level: Int = 5, previous: Int? = nil, direction: Int = 0, magnitude: Int = 0, clamp: String? = nil) {
        self.level = level; self.previous = previous; self.direction = direction
        self.magnitude = magnitude; self.clamp = clamp
    }
}
nonisolated struct DifficultyDecision: Equatable, Sendable {
    let calibration: DifficultyCalibration
    let subject: String?
    let ask: Bool
}

/// Shipping text calibration. Callers own attachment/product/helper and immutable draft gates.
/// No network, persistence, model or mutable conversation state is touched here.
nonisolated enum DifficultyPolicy {
    static let defaultLevel = 5
    static let sourceContractSHA256 = "d785a6ad093b6de0c7f6ec40c149abaa63d350550fa71af9b4616612f8b73ca4"
    private static let jsSpace = "[\\u0009-\\u000D\\u0020\\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000\\uFEFF]"
    private static let jsBoundary = "(?:(?<=[A-Za-z0-9_])(?![A-Za-z0-9_])|(?<![A-Za-z0-9_])(?=[A-Za-z0-9_]))"
    private nonisolated struct JSRegex: Sendable {
        let expression: NSRegularExpression?
        let ignoreCase: Bool
        init(_ source: String, _ ignoreCase: Bool) {
            self.ignoreCase = ignoreCase
            expression = try? NSRegularExpression(pattern: source
                .replacingOccurrences(of: "\\b", with: jsBoundary)
                .replacingOccurrences(of: "\\s", with: jsSpace))
        }
        // ICU caseless matching admits Unicode folds that non-u JS /i does not. These shipping
        // expressions contain ASCII Latin literals; fold ASCII input only, preserving Arabic.
        func contains(_ source: String) -> Bool {
            let text = ignoreCase ? asciiLower(source) : source
            return expression?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        }
        func capture(_ source: String) -> String? {
            let text = ignoreCase ? asciiLower(source) : source
            guard let result = expression?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  result.numberOfRanges > 1, result.range(at: 1).location != NSNotFound else { return nil }
            return (text as NSString).substring(with: result.range(at: 1))
        }
    }
    private nonisolated struct Rung: Sendable {
        let ar: String, en: String, arHint: String, enHint: String
        let concepts: String, steps: String, move: String, answer: String, trap: String, edge: String, fail: String
        init(_ ar: String, _ en: String, _ arHint: String, _ enHint: String, _ concepts: String,
             _ steps: String, _ move: String, _ answer: String, _ trap: String, _ edge: String, _ fail: String) {
            self.ar=ar; self.en=en; self.arHint=arHint; self.enHint=enHint; self.concepts=concepts
            self.steps=steps; self.move=move; self.answer=answer; self.trap=trap; self.edge=edge; self.fail=fail
        }
    }
    private nonisolated struct LexEntry: Sendable {
        let subject: Int, weight: Double, tool: Bool, term: String, gate: String, arabic: Bool, symbol: Bool, regex: JSRegex
        init(_ subject: Int, _ weight: Double, _ tool: Bool, _ term: String, _ gate: String,
             _ arabic: Bool, _ symbol: Bool, _ regex: JSRegex) {
            self.subject=subject; self.weight=weight; self.tool=tool; self.term=term; self.gate=gate
            self.arabic=arabic; self.symbol=symbol; self.regex=regex
        }
    }
    private nonisolated struct Parsed { let absolute: Int?; let direction: Int; let magnitude: Int }
    private static func bounded(_ level: Int) -> Int { min(7, max(1, level)) }
    private static func isJSSpace(_ value: UInt32) -> Bool {
        (0x09...0x0D).contains(value) || value == 0x20 || value == 0xA0 || value == 0x1680 ||
        (0x2000...0x200A).contains(value) || (0x2028...0x2029).contains(value) ||
        value == 0x202F || value == 0x205F || value == 0x3000 || value == 0xFEFF
    }
    private static func trim(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        var start = 0, end = scalars.count
        while start < end && isJSSpace(scalars[start].value) { start += 1 }
        while end > start && isJSSpace(scalars[end - 1].value) { end -= 1 }
        return String(String.UnicodeScalarView(scalars[start..<end]))
    }
    private static func asciiLower(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map {
            (65...90).contains($0.value) ? UnicodeScalar($0.value + 32)! : $0
        }))
    }
    private static func parsed(_ text: String) -> Parsed? {
        if trim(text).isEmpty { return nil }
        if patterns["ASK"]!.contains(trim(text)) && !patterns["TELL"]!.contains(text) { return nil }
        let normalized = String(String.UnicodeScalarView(text.unicodeScalars.map {
            (0x0660...0x0669).contains($0.value) ? UnicodeScalar($0.value - 0x0660 + 48)! : $0
        }))
        if let captured = patterns["SET"]!.capture(normalized), let target = Int(captured) {
            return Parsed(absolute: bounded(target), direction: target > 7 ? 1 : target < 1 ? -1 : 0, magnitude: 0)
        }
        let up = patterns["UP"]!.contains(normalized), down = patterns["DOWN"]!.contains(normalized)
        if up == down { return nil }
        let direction = up ? 1 : -1
        if up && patterns["MAXOUT"]!.contains(normalized) { return Parsed(absolute: 7, direction: 1, magnitude: 4) }
        if down && patterns["MINOUT"]!.contains(normalized) { return Parsed(absolute: 1, direction: -1, magnitude: 4) }
        var magnitude = 2
        if patterns["SMALL"]!.contains(normalized) { magnitude = 1 }
        if patterns["BIG"]!.contains(normalized) { magnitude = 3 }
        if shouting.contains(text) { magnitude = 3 }
        return Parsed(absolute: nil, direction: direction, magnitude: magnitude)
    }
    static func decision(text: String, currentLevel: Int = defaultLevel) -> DifficultyDecision {
        let current = bounded(currentLevel), base = DifficultyCalibration(level: bounded(currentLevel))
        if let parsed = parsed(text) {
            let target = parsed.absolute ?? bounded(current + parsed.direction * parsed.magnitude)
            let edge: String? = parsed.direction > 0 && target == current && current == 7 ? "top" :
                parsed.direction < 0 && target == current && current == 1 ? "bot" : nil
            let calibration = target == current && edge == nil ? base : DifficultyCalibration(
                level: target, previous: current, direction: parsed.direction, magnitude: parsed.magnitude, clamp: edge)
            return DifficultyDecision(calibration: calibration, subject: nil, ask: false)
        }
        if trim(text).isEmpty || !(patterns["noun"]!.contains(text) || patterns["relative"]!.contains(text)) ||
            patterns["sameAR"]!.contains(text) || patterns["sameEN"]!.contains(text) {
            return DifficultyDecision(calibration: base, subject: nil, ask: false)
        }
        let subject = subject(text)
        return DifficultyDecision(calibration: base, subject: subject, ask: subject != nil)
    }
    static func label(level: Int, language: String) -> String {
        let n = bounded(level), rung = ladder[bounded(level) - 1]
        let number = language == "ar" ? String(Array("٠١٢٣٤٥٦٧٨٩")[n]) : String(n)
        return number + " — " + (language == "ar" ? rung.ar : rung.en)
    }
    static func hint(level: Int, language: String) -> String {
        let rung = ladder[bounded(level) - 1]
        return language == "ar" ? rung.arHint : rung.enHint
    }
    private static func spec(_ level: Int) -> String {
        let r = ladder[bounded(level) - 1]
        return "CONCEPTS THAT MUST COMBINE: " + r.concepts +
            ". NON-MECHANICAL STEPS (steps where the solver must DECIDE, not merely execute): " + r.steps +
            ". A NON-OBVIOUS SUBSTITUTION OR TRANSFORMATION: " + r.move +
            ". FORM OF THE ANSWER: " + r.answer + ". TRAP: " + r.trap +
            ". LIMITING OR SPECIAL CASE: " + r.edge + ". WHAT COUNTS AS A FAILURE AT THIS RUNG: " + r.fail + "."
    }
    private static func delta(_ previous: Int, _ level: Int) -> String {
        let a=ladder[bounded(previous)-1], b=ladder[bounded(level)-1]
        return [("concepts that must combine",a.concepts,b.concepts), ("non-mechanical steps",a.steps,b.steps),
            ("a non-obvious substitution or transformation",a.move,b.move), ("the form of the answer",a.answer,b.answer),
            ("the trap",a.trap,b.trap), ("the limiting or special case",a.edge,b.edge)]
            .map { "\($0.0): WAS [\($0.1)] → IS NOW [\($0.2)]" }.joined(separator: "; ")
    }
    static func rule(_ calibration: DifficultyCalibration) -> String {
        let level = bounded(calibration.level), previous = calibration.previous.map(bounded)
        let degree: String
        switch calibration.magnitude {
        case 1: degree="a SMALL step"; case 3: degree="a LARGE step"; case 4: degree="as far as this ladder goes"
        case 2: degree="a clear step"; default: degree="a level they chose directly"
        }
        func fill(_ template: String) -> String {
            template.replacingOccurrences(of: "@@LEVEL@@", with: String(level))
                .replacingOccurrences(of: "@@NAME@@", with: ladder[level-1].en)
                .replacingOccurrences(of: "@@SPEC@@", with: spec(level))
                .replacingOccurrences(of: "@@PREVIOUS@@", with: String(previous ?? level))
                .replacingOccurrences(of: "@@PREVIOUS_NAME@@", with: ladder[(previous ?? level)-1].en)
                .replacingOccurrences(of: "@@DELTA@@", with: delta(previous ?? level,level))
                .replacingOccurrences(of: "@@DEGREE@@", with: degree)
        }
        let suffix: String
        if calibration.clamp == "top" && level == 7 { suffix=topTemplate }
        else if calibration.clamp == "bot" && level == 1 { suffix=bottomTemplate }
        else if let previous, previous != level {
            // Shipping zero-direction heading and tail use different comparisons.
            suffix=calibration.direction > 0 ? upTemplate : calibration.direction < 0 ? downTemplate : directTemplate
        }
        else { suffix="" }
        return fill(baseTemplate) + fill(suffix)
    }
    private static func normalize(_ text: String) -> String {
        let head = String(decoding: text.utf16.prefix(4000), as: UTF16.self)
        let scalars = head.lowercased().precomposedStringWithCompatibilityMapping.unicodeScalars
        var result = ""
        for scalar in scalars {
            let v=scalar.value
            if (0x200B...0x200F).contains(v) || v == 0x061C || (0x202A...0x202E).contains(v) ||
                (0x2066...0x2069).contains(v) || v == 0xFEFF || (0x064B...0x0652).contains(v) ||
                v == 0x0670 || v == 0x0640 || (0x06D6...0x06ED).contains(v) { continue }
            let mapped: UnicodeScalar
            switch v {
            case 0x0660...0x0669: mapped=UnicodeScalar(v-0x0660+48)!
            case 0x06F0...0x06F9: mapped=UnicodeScalar(v-0x06F0+48)!
            case 0x0622,0x0623,0x0625,0x0671: mapped="ا"
            case 0x0629: mapped="ه"; case 0x0649: mapped="ي"; case 0x0624: mapped="و"; case 0x0626: mapped="ي"
            default: mapped=scalar
            }
            if isJSSpace(mapped.value) { if !result.hasSuffix(" ") { result += " " } }
            else { result.unicodeScalars.append(mapped) }
        }
        return trim(result)
    }
    private static func subject(_ text: String) -> String? {
        let value=normalize(text)
        let hasArabic=value.unicodeScalars.contains { (0x0621...0x064A).contains($0.value) }
        let hasLatin=value.unicodeScalars.contains { (97...122).contains($0.value) }
        if !hasArabic && !hasLatin { return nil }
        var core=[0.0,0.0,0.0], tools=[0.0,0.0,0.0]
        for entry in lexicon {
            if !entry.symbol && (entry.arabic ? !hasArabic : !hasLatin) { continue }
            if !value.contains(entry.gate) || !entry.regex.contains(value) { continue }
            if entry.tool { tools[entry.subject] += entry.weight } else { core[entry.subject] += entry.weight }
        }
        let scores=(0...2).map { n -> Double in
            let rival=(0...2).contains { $0 != n && core[$0] > 0 }
            return floor((core[n]+tools[n]*(core[n] == 0 && rival ? 0.25 : 1))*100+0.5)/100
        }
        let ranked=(0...2).sorted { scores[$0] > scores[$1] }
        if scores[ranked[0]] < 1 || scores[ranked[0]]-scores[ranked[1]] < 0.75 { return nil }
        return ["math","physics","chemistry"][ranked[0]]
    }
    private static let shouting=JSRegex("\\b(?:HARDER|TOUGHER|EASIER|SIMPLER|MUCH|WAY)\\b", false)
    private static let ladder: [Rung] = [
        Rung("تأسيس", "Foundation", "فكرة واحدة وخطوة أو خطوتان، بلا فخاخ", "One idea, one or two steps, no traps", "exactly one, from a single section of one chapter", "one or two, and every one of them mechanical - substitute into a stated formula, or make one rearrangement", "FORBIDDEN - the first method a beginner reaches for must work from start to finish", "a bare number or a single symbol, correct as written, with nothing left to simplify", "none - nothing in the wording may mislead, and there is no plausible wrong route to fall into", "none - no boundary, no domain restriction, no special case", "an item that needs two ideas, a calculator, or a moment's thought about WHICH method to use"),
        Rung("تمرين", "Drill", "مفهوم واحد بالطريقة المباشرة", "One concept, the direct method", "one, though a second may appear as a formula that is simply looked up and applied", "two or three, all mechanical, in a fixed order the student has already practised", "FORBIDDEN - the standard method applies directly", "a bare number, a simple fraction, or a single surd", "none", "none", "any item where the student must CHOOSE between two methods"),
        Rung("منهجي", "Standard", "مفهومان من الباب نفسه — مستوى المنهج", "Two concepts from one chapter - curriculum level", "two, from the same chapter, both named openly by the problem", "three or four, of which AT MOST ONE requires a decision (which identity, which formula, which order)", "not required; a standard technique applied in the obvious way must be enough", "a closed form that needs one line of simplification", "none deliberate", "none required", "a one-line plug-in (too easy for this rung) or anything needing a substitution nobody would guess (too hard for it)"),
        Rung("تحليلي", "Analytical", "بابان يلتقيان، والطريق اختيار لا تنفيذ", "Two chapters meet; the route is a choice", "two DISTINCT ones from DIFFERENT sections, and neither alone reaches the answer - the item exists to make them meet", "four to six, at least two of them non-mechanical (the solver chooses a route rather than following one)", "not required, but the first attempt anyone makes should be the LONGER one, so that a better-chosen standard technique visibly pays off", "a closed form that must be simplified; no rounded decimals", "one plausible shortcut that yields a specific wrong value - reachable, and avoidable by a careful reader", "not required", "anything answered by substituting into a single formula"),
        Rung("متقدّم", "Advanced", "ثلاثة مفاهيم وتعويض غير بديهي لازم", "Three concepts; one non-obvious move is required", "three distinct ones, at least two from different chapters, and the link between them is part of what has to be discovered", "six to nine, at least three of them non-mechanical", "REQUIRED - exactly one non-obvious substitution, change of variable or frame, symmetry/parity argument, reformulation or auxiliary quantity, WITHOUT which the direct route becomes impractically long", "a simplified closed form (fraction, radical, pi, e, ln, exact symbolic expression) - never a rounded decimal", "one deliberate plausible-but-wrong route", "the solution must verify itself against one limit, boundary or special case BEFORE stating the final answer", "a problem that looks hard and then yields to the direct method"),
        Rung("تنافسي", "Competition", "حركتان غير بديهيتين وفخّ مقصود وحالات", "Two non-obvious moves, a deliberate trap, cases", "three or more from DIFFERENT chapters, plus one prerequisite the statement never names", "eight to fourteen, at least five of them non-mechanical", "at least TWO INDEPENDENT non-obvious moves - for instance a substitution AND an invariance or symmetry argument, or a clever splitting AND a bounding step; either one alone must be insufficient", "a closed form whose final simplification is itself non-trivial", "at least one route that looks right and produces a specific, plausible wrong answer - never hinted at in the statement", "the solution must split into two or more cases, or handle a domain/boundary restriction that is easy to miss", "a strong student finishing it in under five minutes, or a trap that would catch nobody"),
        Rung("أولمبي", "Olympiad", "يحتاج فكرة لا تقنية، والجواب يُبرهَن", "Needs an idea, not a technique - and a proof", "whatever the IDEA needs; this rung is not measured in chapters. The item must require an insight rather than a technique - an invariant or monovariant, an extremal or pigeonhole argument, an auxiliary construction, a well-chosen inequality, a generating function, a non-obvious induction", "a structured argument rather than a computation; a solver who knows every standard method and has no insight must FAIL", "the natural approach must genuinely fail or blow up, and the solution must say in one line why", "PROVED, not merely computed - existence, uniqueness, or a bound established and then shown to be attained", "the obvious route IS the trap", "every case exhausted; nothing left to the reader", "anything a known algorithm solves, and any answer stated without justification"),
    ]
    private static let patterns: [String: JSRegex] = [
        "UP": JSRegex("(?:\\u0623\\u0635\\u0639\\u0628|\\u0627\\u0635\\u0639\\u0628|\\u0635\\u0639\\u0651\\u0628|\\u0635\\u0639\\u0628(?:\\u0647\\u0627|\\u0647\\u0645|\\u0647\\u0646|\\u0647)|\\u0639\\u0642\\u0651\\u062f|\\u0639\\u0642\\u062f(?:\\u0647\\u0627|\\u0647\\u0645)|\\u0623\\u0639\\u0642\\u062f|\\u0627\\u0639\\u0642\\u062f|\\u0623\\u0642\\u0648\\u0649|\\u0627\\u0642\\u0648\\u0649|\\u0623\\u062b\\u0642\\u0644|\\u0627\\u062b\\u0642\\u0644|\\u0627\\u0631\\u0641\\u0639\\s*(?:\\u0627\\u0644)?(?:\\u0635\\u0639\\u0648\\u0628|\\u0645\\u0633\\u062a\\u0648)|\\u0632\\u062f\\s*(?:\\u0627\\u0644)?(?:\\u0635\\u0639\\u0648\\u0628|\\u0645\\u0633\\u062a\\u0648)|\\u0632\\u0648\\u0651?\\u062f\\s*(?:\\u0627\\u0644)?(?:\\u0635\\u0639\\u0648\\u0628|\\u0645\\u0633\\u062a\\u0648)|\\u0645\\u0633\\u062a\\u0648\\u0649\\s*\\u0623\\u0639\\u0644\\u0649|\\u062a\\u062d\\u062f\\u0651?\\u064a\\s*\\u0623\\u0643\\u0628\\u0631|\\u0623\\u0643\\u062b\\u0631\\s*(?:\\u0635\\u0639\\u0648\\u0628\\u0629|\\u062a\\u0639\\u0642\\u064a\\u062f\\u064b?\\u0627|\\u062a\\u062d\\u062f\\u0651?\\u064a\\u064b?\\u0627))|\\b(?:harder|hardest|tougher|toughest|more\\s*difficult|more\\s*challenging|more\\s*advanced|as\\s*hard\\s*as\\s*possible|level\\s*(?:it\\s*)?up|step\\s*it\\s*up|crank\\s*(?:it\\s*)?up|raise\\s*the\\s*difficulty|increase\\s*the\\s*difficulty|max(?:imum)?\\s*difficulty|beef\\s*(?:it|them)?\\s*up|spicier)\\b", true),
        "DOWN": JSRegex("(?:\\u0623\\u0633\\u0647\\u0644|\\u0627\\u0633\\u0647\\u0644|\\u0633\\u0647\\u0651\\u0644|\\u0633\\u0647\\u0644(?:\\u0647\\u0627|\\u0647\\u0645|\\u0647\\u0646|\\u0647)|\\u0628\\u0633\\u0651\\u0637|\\u0628\\u0633\\u0637(?:\\u0647\\u0627|\\u0647\\u0645)|\\u0623\\u0628\\u0633\\u0637|\\u0627\\u0628\\u0633\\u0637|\\u062e\\u0641\\u0651\\u0641|\\u062e\\u0641\\u0641|\\u0642\\u0644\\u0651?\\u0644\\s*(?:\\u0627\\u0644)?\\u0635\\u0639\\u0648\\u0628|\\u0646\\u0632\\u0651?\\u0644\\s*(?:\\u0627\\u0644)?(?:\\u0635\\u0639\\u0648\\u0628|\\u0645\\u0633\\u062a\\u0648)|\\u0645\\u0633\\u062a\\u0648\\u0649\\s*\\u0623\\u0642\\u0644|\\u0623\\u0642\\u0644\\s*\\u0635\\u0639\\u0648\\u0628\\u0629|\\u0644\\u0644\\u0645\\u0628\\u062a\\u062f\\u0626\\u064a\\u0646|\\u0645\\u0633\\u062a\\u0648\\u0649\\s*\\u0645\\u0628\\u062a\\u062f\\u0626)|\\b(?:easier|easiest|simpler|simplest|less\\s*difficult|less\\s*challenging|lighter|as\\s*easy\\s*as\\s*possible|tone\\s*(?:it|them)?\\s*down|dial\\s*(?:it|them)?\\s*(?:back|down)|dumb\\s*(?:it|them)?\\s*down|more\\s*basic|beginner\\s*level|for\\s*a\\s*(?:complete\\s*)?beginner|absolute\\s*basics|lower\\s*the\\s*difficulty|reduce\\s*the\\s*difficulty)\\b", true),
        "BIG": JSRegex("(?:\\u0628\\u0643\\u062b\\u064a\\u0631|\\u0643\\u062b\\u064a\\u0631\\u064b?\\u0627\\u064b?(?![\\u0621-\\u064a])|\\u0628\\u0634\\u0643\\u0644\\s*\\u0643\\u0628\\u064a\\u0631|\\u062c\\u062f\\u0651?\\u064b?\\u0627\\u064b?(?![\\u0621-\\u064a])|\\u0623\\u0636\\u0639\\u0627\\u0641|\\u0627\\u0636\\u0639\\u0627\\u0641|\\u0636\\u0627\\u0639\\u0641|\\u062f\\u0631\\u062c\\u062a\\u064a\\u0646|\\u0645\\u0633\\u062a\\u0648\\u064a\\u064a\\u0646)|\\b(?:much|way|far|a\\s*lot|lots|significantly|considerably|substantially|two\\s*(?:levels?|notches))\\b", true),
        "SMALL": JSRegex("(?:\\u0634\\u0648\\u064a\\u0629|\\u0634\\u0648\\u064a|\\u0642\\u0644\\u064a\\u0644\\u064b?\\u0627|\\u0628\\u0642\\u0644\\u064a\\u0644|\\u0637\\u0641\\u064a\\u0641|\\u0628\\u0633\\u064a\\u0637|\\u062f\\u0631\\u062c\\u0629\\s*(?:\\u0648\\u0627\\u062d\\u062f\\u0629|\\u0648\\u062d\\u062f\\u0629|\\u0641\\u0642\\u0637))|\\b(?:a\\s*bit|a\\s*little|slightly|slight|somewhat|a\\s*touch|marginally|one\\s*(?:level|notch))\\b", true),
        "MAXOUT": JSRegex("(?:\\u0623\\u0642\\u0635\\u0649|\\u0627\\u0642\\u0635\\u0649|\\u0644\\u0623\\u0642\\u0635\\u0649|\\u0623\\u0635\\u0639\\u0628\\s*\\u0645\\u0627\\s*\\u064a\\u0645\\u0643\\u0646|\\u062c\\u0647\\u0646\\u0645\\u064a|\\u062a\\u0639\\u062c\\u064a\\u0632\\u064a)|\\b(?:as\\s*hard\\s*as\\s*possible|hardest\\s*possible|maximum\\s*difficulty|max\\s*difficulty|insane|brutal|extreme)\\b", true),
        "MINOUT": JSRegex("(?:\\u0623\\u0633\\u0647\\u0644\\s*\\u0645\\u0627\\s*\\u064a\\u0645\\u0643\\u0646|\\u0623\\u0628\\u0633\\u0637\\s*\\u0645\\u0627\\s*\\u064a\\u0645\\u0643\\u0646|\\u0644\\u0644\\u0645\\u0628\\u062a\\u062f\\u0626\\u064a\\u0646|\\u0645\\u0646\\s*\\u0627\\u0644\\u0635\\u0641\\u0631|\\u0645\\u0633\\u062a\\u0648\\u0649\\s*\\u0645\\u0628\\u062a\\u062f\\u0626)|\\b(?:as\\s*easy\\s*as\\s*possible|easiest\\s*possible|absolute\\s*basics|for\\s*a\\s*(?:complete\\s*)?beginner|beginner\\s*level)\\b", true),
        "SET": JSRegex("(?:\\u0627\\u0644\\u0645\\u0633\\u062a\\u0648\\u0649|\\u0645\\u0633\\u062a\\u0648\\u0649|\\u0627\\u0644\\u0635\\u0639\\u0648\\u0628\\u0629|\\u0635\\u0639\\u0648\\u0628\\u0629|difficulty|level)\\s*(?:[:=]\\s*)?(?:\\u0631\\u0642\\u0645\\s*)?([0-9]{1,2})(?![0-9])", true),
        "ASK": JSRegex("[?\\u061F]\\s*$|^\\s*(?:ما\\b|ماذا|شنو|أيّ?هما|أيّ?\\b|هل\\b|كم\\b|what|which|is|are|how)\\b", true),
        "TELL": JSRegex("خلّ?ي|خليها|سوّ?ي|اعمل|اعطني|أعطني|اجعل|زد|زيد|نزّ?ل|قلّ?ل|ارفع|(?<![أا])صعّ?ب|(?<![أا])بسّ?ط|\\bmake\\b|\\bgive\\b|\\bset\\b|\\bdo\\b|\\bturn\\b|\\bbump\\b", true),
        "noun": JSRegex("(\\u0623\\u0633\\u0626\\u0644\\u0629|\\u0627\\u0633\\u0626\\u0644\\u0629|\\u0633\\u0624\\u0627\\u0644|\\u0645\\u0633\\u0627\\u0626\\u0644|\\u0645\\u0633\\u0623\\u0644|\\u062a\\u0645\\u0627\\u0631\\u064a\\u0646|\\u062a\\u0645\\u0631\\u064a\\u0646|\\u062a\\u0643\\u0627\\u0645\\u0644|\\u0645\\u0639\\u0627\\u062f\\u0644|\\u0627\\u0645\\u062a\\u062d\\u0627\\u0646|\\u0627\\u062e\\u062a\\u0628\\u0627\\u0631|\\u0643\\u0648\\u064a\\u0632|\\u0645\\u0633\\u0627\\u0628\\u0642\\u0629|problems?|questions?|exercises?|integrals?|equations?|exams?|quiz|quizzes|worksheets?|tests?|mcqs?)", true),
        "relative": JSRegex("(\\u0623\\u0635\\u0639\\u0628|\\u0627\\u0635\\u0639\\u0628|\\u0623\\u0633\\u0647\\u0644|\\u0627\\u0633\\u0647\\u0644|\\u0635\\u0639\\u0651?\\u0628\\u0647\\u0627|\\u0633\\u0647\\u0651?\\u0644\\u0647\\u0627|\\u0632\\u062f\\u0646\\u064a)|make\\s+(?:it|them)\\s+(?:harder|easier|tougher|simpler)|\\b(?:harder|tougher|easier)\\b", true),
        "sameAR": JSRegex("(\\u0645\\u0634\\u0627\\u0628\\u0647|\\u0645\\u0645\\u0627\\u062b\\u0644|\\u0634\\u0628\\u064a\\u0647|\\u0639\\u0644\\u0649\\s*\\u063a\\u0631\\u0627\\u0631|\\u0645\\u062b\\u0644\\s*(?:\\u0647\\u0630[\\u0647\\u0627\\u064a]|\\u0647\\u0627\\u064a|\\u0627\\u0644\\u0633\\u0627\\u0628\\u0642|\\u0627\\u0644\\u0644\\u064a)|(?:\\u0628)?\\u0646\\u0641\\u0633\\s*(?:\\u0627\\u0644\\u0646\\u0645\\u0637|\\u0627\\u0644\\u0623\\u0633\\u0644\\u0648\\u0628|\\u0627\\u0644\\u0627\\u0633\\u0644\\u0648\\u0628|\\u0627\\u0644\\u0637\\u0631\\u064a\\u0642\\u0629|\\u0627\\u0644\\u0634\\u0643\\u0644|\\u0627\\u0644\\u0641\\u0643\\u0631\\u0629))", false),
        "sameEN": JSRegex("(similar|same\\s*(?:pattern|style|format|type|idea|kind|lines)|like\\s*(?:this|these|those|the\\s*(?:above|previous|last))|modell?ed\\s*on|along\\s*the\\s*same\\s*lines|in\\s*the\\s*same\\s*vein)", true),
    ]
    private static let lexicon: [LexEntry] = [
        LexEntry(0, 2.0, false, "رياضيات", "رياضيات", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?رياضيات(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(0, 2.0, false, "ماث", "ماث", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?ماث(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(0, 2.0, false, "math", "math", false, false, JSRegex("(?:^|[^a-z0-9])math(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(0, 2.0, false, "maths", "maths", false, false, JSRegex("(?:^|[^a-z0-9])maths(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(0, 2.0, false, "mathematics", "mathematics", false, false, JSRegex("(?:^|[^a-z0-9])mathematics(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(0, 2.0, false, "calculus", "calculus", false, false, JSRegex("(?:^|[^a-z0-9])calculus(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(0, 1.5, false, "جبر", "جبر", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?جبر(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(0, 1.5, false, "algebra", "algebra", false, false, JSRegex("(?:^|[^a-z0-9])algebra(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(0, 1.5, false, "geometry", "geometry", false, false, JSRegex("(?:^|[^a-z0-9])geometry(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(0, 1.5, false, "trigonometry", "trigonometry", false, false, JSRegex("(?:^|[^a-z0-9])trigonometry(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(0, 1.5, false, "مثلثات", "مثلثات", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?مثلثات(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(0, 1.5, false, "مصفوفه", "مصفوف", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?مصفوف(?:ه|ت)(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(0, 1.5, false, "matrix", "matrix", false, false, JSRegex("(?:^|[^a-z0-9])matrix(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(0, 1.5, false, "matrices", "matrices", false, false, JSRegex("(?:^|[^a-z0-9])matrices(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(0, 1.5, false, "محددات", "محددات", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?محددات(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(0, 1.5, false, "متسلسله", "متسلسل", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?متسلسل(?:ه|ت)(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(0, 1.5, false, "متتاليه", "متتالي", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?متتالي(?:ه|ت)(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(0, 1.5, false, "تباديل", "تباديل", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?تباديل(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(0, 1.5, false, "توافيق", "توافيق", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?توافيق(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(0, 1.5, false, "permutation", "permutation", false, false, JSRegex("(?:^|[^a-z0-9])permutation(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(0, 1.5, false, "متباينه", "متباين", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?متباين(?:ه|ت)(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(0, 1.5, false, "inequality", "inequality", false, false, JSRegex("(?:^|[^a-z0-9])inequality(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(0, 1.5, false, "هندسه تحليليه", "هندس", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?هندس(?:ه|ت)\\s+(?:ال)?تحليلي(?:ه|ت)(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(0, 1.5, false, "هندسه فراغيه", "هندس", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?هندس(?:ه|ت)\\s+(?:ال)?فراغي(?:ه|ت)(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(0, 1.5, false, "هندسه مستويه", "هندس", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?هندس(?:ه|ت)\\s+(?:ال)?مستوي(?:ه|ت)(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(0, 1.5, false, "عدد اولي", "عدد", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?عدد\\s+(?:ال)?اولي(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(0, 1.5, false, "prime number", "prime", false, false, JSRegex("(?:^|[^a-z0-9])prime\\s+number(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(0, 1.5, false, "اعداد مركبه", "اعداد", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?اعداد\\s+(?:ال)?مركب(?:ه|ت)(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(0, 1.5, false, "complex number", "complex", false, false, JSRegex("(?:^|[^a-z0-9])complex\\s+number(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(0, 1.5, false, "فيثاغورس", "فيثاغورس", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?فيثاغورس(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(0, 1.5, false, "pythagoras", "pythagoras", false, false, JSRegex("(?:^|[^a-z0-9])pythagoras(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(0, 1.5, false, "theorem", "theorem", false, false, JSRegex("(?:^|[^a-z0-9])theorem(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(0, 1.5, false, "مبرهنه", "مبرهن", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?مبرهن(?:ه|ت)(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(0, 1.5, false, "قطع مكافي", "قطع", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?قطع\\s+(?:ال)?مكافي(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(0, 1.5, false, "قطع ناقص", "قطع", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?قطع\\s+(?:ال)?ناقص(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(0, 1.5, false, "قطع زايد", "قطع", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?قطع\\s+(?:ال)?زايد(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(0, 1.5, false, "parabola", "parabola", false, false, JSRegex("(?:^|[^a-z0-9])parabola(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(0, 1.5, false, "ellipse", "ellipse", false, false, JSRegex("(?:^|[^a-z0-9])ellipse(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(0, 1.5, false, "hyperbola", "hyperbola", false, false, JSRegex("(?:^|[^a-z0-9])hyperbola(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(0, 1.5, false, "probability", "probability", false, false, JSRegex("(?:^|[^a-z0-9])probability(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(0, 1.5, false, "اقتران", "اقتران", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?اقتران(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(0, 1.5, false, "quadratic", "quadratic", false, false, JSRegex("(?:^|[^a-z0-9])quadratic(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(0, 1.5, false, "نظريه الاعداد", "نظري", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?نظري(?:ه|ت)\\s+(?:ال)?الاعداد(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(0, 1.5, false, "number theory", "number", false, false, JSRegex("(?:^|[^a-z0-9])number\\s+theory(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(0, 1.5, false, "جذر تربيعي", "جذر", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?جذر\\s+(?:ال)?تربيعي(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(0, 1.5, false, "square root", "square", false, false, JSRegex("(?:^|[^a-z0-9])square\\s+root(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(0, 1.0, false, "احتمالات", "احتمالات", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?احتمالات(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(0, 1.0, false, "احتماليه", "احتمالي", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?احتمالي(?:ه|ت)(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(0, 1.0, false, "تربيعي", "تربيعي", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?تربيعي(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(0, 1.0, false, "برهن", "برهن", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?برهن(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(0, 1.0, false, "proof", "proof", false, false, JSRegex("(?:^|[^a-z0-9])proof(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(0, 1.0, false, "logarithm", "logarithm", false, false, JSRegex("(?:^|[^a-z0-9])logarithm(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(0, 1.0, false, "لوغاريتم", "لوغاريتم", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?لوغاريتم(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(0, 1.0, false, "احصاء", "احصاء", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?احصاء(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(0, 1.0, false, "statistics", "statistics", false, false, JSRegex("(?:^|[^a-z0-9])statistics(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(0, 1.0, false, "متوسط حسابي", "متوسط", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?متوسط\\s+(?:ال)?حسابي(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(0, 1.0, false, "انحراف معياري", "انحراف", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?انحراف\\s+(?:ال)?معياري(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(0, 0.6, false, "احتمال", "احتمال", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?احتمال(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(0, 0.6, false, "هندسه", "هندس", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?هندس(?:ه|ت)(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(0, 0.6, false, "كسور", "كسور", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?كسور(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(0, 0.6, false, "fraction", "fraction", false, false, JSRegex("(?:^|[^a-z0-9])fraction(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(0, 0.6, false, "جذر", "جذر", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?جذر(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(0, 0.6, false, "combination", "combination", false, false, JSRegex("(?:^|[^a-z0-9])combination(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(0, 0.6, false, "مجموعات", "مجموعات", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?مجموعات(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(0, 0.6, false, "series", "series", false, false, JSRegex("(?:^|[^a-z0-9])series(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(0, 0.6, false, "sequence", "sequence", false, false, JSRegex("(?:^|[^a-z0-9])sequence(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(0, 0.6, false, "برهان", "برهان", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?برهان(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(0, 1.5, true, "تكامل", "تكامل", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?تكامل(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(0, 1.5, true, "تفاضل", "تفاضل", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?تفاضل(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(0, 1.5, true, "مشتقه", "مشتق", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?مشتق(?:ه|ت)(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(0, 1.5, true, "integral", "integral", false, false, JSRegex("(?:^|[^a-z0-9])integral(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(0, 1.5, true, "integration", "integration", false, false, JSRegex("(?:^|[^a-z0-9])integration(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(0, 1.5, true, "derivative", "derivative", false, false, JSRegex("(?:^|[^a-z0-9])derivative(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(0, 1.5, true, "differentiation", "differentiation", false, false, JSRegex("(?:^|[^a-z0-9])differentiation(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(0, 1.5, true, "antiderivative", "antiderivative", false, false, JSRegex("(?:^|[^a-z0-9])antiderivative(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(0, 1.0, true, "اشتقاق", "اشتقاق", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?اشتقاق(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(0, 1.0, true, "نهايات", "نهايات", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?نهايات(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(0, 1.0, true, "داله", "دال", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?دال(?:ه|ت)(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(0, 1.0, true, "متجه", "متج", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?متج(?:ه|ت)(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(0, 1.0, true, "vector", "vector", false, false, JSRegex("(?:^|[^a-z0-9])vector(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(0, 1.0, true, "معادله تفاضليه", "معادل", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?معادل(?:ه|ت)\\s+(?:ال)?تفاضلي(?:ه|ت)(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(0, 1.5, true, "∫", "∫", false, true, JSRegex("∫", false)),
        LexEntry(0, 1.5, true, "\\int", "\\int", false, false, JSRegex("(?:^|[^a-z0-9])\\\\int(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(0, 1.5, true, "∮", "∮", false, true, JSRegex("∮", false)),
        LexEntry(0, 1.0, true, "∑", "∑", false, true, JSRegex("∑", false)),
        LexEntry(0, 1.0, true, "∂", "∂", false, true, JSRegex("∂", false)),
        LexEntry(0, 1.0, true, "\\sum", "\\sum", false, false, JSRegex("(?:^|[^a-z0-9])\\\\sum(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(0, 1.0, true, "\\lim", "\\lim", false, false, JSRegex("(?:^|[^a-z0-9])\\\\lim(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(0, 0.6, true, "معادله", "معادل", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?معادل(?:ه|ت)(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(0, 0.6, true, "equation", "equation", false, false, JSRegex("(?:^|[^a-z0-9])equation(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(0, 0.6, true, "function", "function", false, false, JSRegex("(?:^|[^a-z0-9])function(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(0, 0.6, true, "نهايه", "نهاي", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?نهاي(?:ه|ت)(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(0, 0.6, true, "limit", "limit", false, false, JSRegex("(?:^|[^a-z0-9])limit(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(0, 0.6, true, "متغير", "متغير", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?متغير(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(0, 0.6, true, "variable", "variable", false, false, JSRegex("(?:^|[^a-z0-9])variable(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(0, 0.6, true, "مساحه", "مساح", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?مساح(?:ه|ت)(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(0, 0.6, true, "محيط", "محيط", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?محيط(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(0, 0.6, true, "زاويه", "زاوي", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?زاوي(?:ه|ت)(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(0, 0.6, true, "angle", "angle", false, false, JSRegex("(?:^|[^a-z0-9])angle(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(0, 0.6, true, "مثلث", "مثلث", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?مثلث(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(0, 0.6, true, "مسافه", "مساف", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?مساف(?:ه|ت)(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(0, 0.6, true, "distance", "distance", false, false, JSRegex("(?:^|[^a-z0-9])distance(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(1, 2.0, false, "فيزيا", "فيزيا", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?فيزيا(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(1, 2.0, false, "فيزيايي", "فيزيايي", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?فيزيايي(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(1, 2.0, false, "physics", "physics", false, false, JSRegex("(?:^|[^a-z0-9])physics(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(1, 2.0, false, "kinematics", "kinematics", false, false, JSRegex("(?:^|[^a-z0-9])kinematics(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(1, 1.5, false, "ميكانيك", "ميكانيك", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?ميكانيك(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(1, 1.5, false, "ميكانيكا", "ميكانيكا", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?ميكانيكا(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(1, 1.5, false, "mechanics", "mechanics", false, false, JSRegex("(?:^|[^a-z0-9])mechanics(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(1, 1.5, false, "زخم", "زخم", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?زخم(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(1, 1.5, false, "momentum", "momentum", false, false, JSRegex("(?:^|[^a-z0-9])momentum(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(1, 1.5, false, "تسارع", "تسارع", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?تسارع(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(1, 1.5, false, "acceleration", "acceleration", false, false, JSRegex("(?:^|[^a-z0-9])acceleration(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(1, 1.5, false, "velocity", "velocity", false, false, JSRegex("(?:^|[^a-z0-9])velocity(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(1, 1.5, false, "احتكاك", "احتكاك", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?احتكاك(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(1, 1.5, false, "friction", "friction", false, false, JSRegex("(?:^|[^a-z0-9])friction(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(1, 1.5, false, "سقوط حر", "سقوط", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?سقوط\\s+(?:ال)?حر(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(1, 1.5, false, "free fall", "free", false, false, JSRegex("(?:^|[^a-z0-9])free\\s+fall(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(1, 1.5, false, "نيوتن", "نيوتن", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?نيوتن(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(1, 1.5, false, "newton", "newton", false, false, JSRegex("(?:^|[^a-z0-9])newton(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(1, 1.5, false, "joule", "joule", false, false, JSRegex("(?:^|[^a-z0-9])joule(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(1, 1.5, false, "كهرباء", "كهرباء", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?كهرباء(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(1, 1.5, false, "electricity", "electricity", false, false, JSRegex("(?:^|[^a-z0-9])electricity(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(1, 1.5, false, "فولت", "فولت", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?فولت(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(1, 1.5, false, "volt", "volt", false, false, JSRegex("(?:^|[^a-z0-9])volt(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(1, 1.5, false, "voltage", "voltage", false, false, JSRegex("(?:^|[^a-z0-9])voltage(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(1, 1.5, false, "مكثف", "مكثف", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?مكثف(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(1, 1.5, false, "capacitor", "capacitor", false, false, JSRegex("(?:^|[^a-z0-9])capacitor(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(1, 1.5, false, "resistor", "resistor", false, false, JSRegex("(?:^|[^a-z0-9])resistor(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(1, 1.5, false, "دايره كهرباييه", "داير", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?داير(?:ه|ت)\\s+(?:ال)?كهربايي(?:ه|ت)(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(1, 1.5, false, "circuit", "circuit", false, false, JSRegex("(?:^|[^a-z0-9])circuit(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(1, 1.5, false, "امبير", "امبير", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?امبير(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(1, 1.5, false, "ampere", "ampere", false, false, JSRegex("(?:^|[^a-z0-9])ampere(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(1, 1.5, false, "مغناطيس", "مغناطيس", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?مغناطيس(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(1, 1.5, false, "magnet", "magnet", false, false, JSRegex("(?:^|[^a-z0-9])magnet(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(1, 1.5, false, "magnetic", "magnetic", false, false, JSRegex("(?:^|[^a-z0-9])magnetic(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(1, 1.5, false, "magnetism", "magnetism", false, false, JSRegex("(?:^|[^a-z0-9])magnetism(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(1, 1.5, false, "كهرومغناطيسي", "كهرومغناطيسي", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?كهرومغناطيسي(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(1, 1.5, false, "electromagnetic", "electromagnetic", false, false, JSRegex("(?:^|[^a-z0-9])electromagnetic(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(1, 1.5, false, "طول موجي", "طول", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?طول\\s+(?:ال)?موجي(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(1, 1.5, false, "wavelength", "wavelength", false, false, JSRegex("(?:^|[^a-z0-9])wavelength(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(1, 1.5, false, "بندول", "بندول", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?بندول(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(1, 1.5, false, "pendulum", "pendulum", false, false, JSRegex("(?:^|[^a-z0-9])pendulum(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(1, 1.5, false, "نابض", "نابض", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?نابض(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(1, 1.5, false, "بصريات", "بصريات", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?بصريات(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(1, 1.5, false, "optics", "optics", false, false, JSRegex("(?:^|[^a-z0-9])optics(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(1, 1.5, false, "انكسار", "انكسار", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?انكسار(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(1, 1.5, false, "refraction", "refraction", false, false, JSRegex("(?:^|[^a-z0-9])refraction(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(1, 1.5, false, "عدسه", "عدس", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?عدس(?:ه|ت)(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(1, 1.5, false, "lens", "lens", false, false, JSRegex("(?:^|[^a-z0-9])lens(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(1, 1.5, false, "حيود", "حيود", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?حيود(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(1, 1.5, false, "diffraction", "diffraction", false, false, JSRegex("(?:^|[^a-z0-9])diffraction(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(1, 1.5, false, "نووي", "نووي", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?نووي(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(1, 1.5, false, "nuclear", "nuclear", false, false, JSRegex("(?:^|[^a-z0-9])nuclear(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(1, 1.5, false, "نشاط اشعاعي", "نشاط", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?نشاط\\s+(?:ال)?اشعاعي(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(1, 1.5, false, "radioactive", "radioactive", false, false, JSRegex("(?:^|[^a-z0-9])radioactive(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(1, 1.5, false, "انشطار", "انشطار", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?انشطار(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(1, 1.5, false, "fission", "fission", false, false, JSRegex("(?:^|[^a-z0-9])fission(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(1, 1.5, false, "فوتون", "فوتون", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?فوتون(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(1, 1.5, false, "photon", "photon", false, false, JSRegex("(?:^|[^a-z0-9])photon(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(1, 1.5, false, "كوانتم", "كوانتم", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?كوانتم(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(1, 1.5, false, "quantum", "quantum", false, false, JSRegex("(?:^|[^a-z0-9])quantum(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(1, 1.5, false, "نسبيه", "نسبي", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?نسبي(?:ه|ت)(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(1, 1.5, false, "relativity", "relativity", false, false, JSRegex("(?:^|[^a-z0-9])relativity(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(1, 1.5, false, "جاذبيه", "جاذبي", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?جاذبي(?:ه|ت)(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(1, 1.5, false, "gravity", "gravity", false, false, JSRegex("(?:^|[^a-z0-9])gravity(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(1, 1.5, false, "gravitation", "gravitation", false, false, JSRegex("(?:^|[^a-z0-9])gravitation(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(1, 1.5, false, "torque", "torque", false, false, JSRegex("(?:^|[^a-z0-9])torque(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(1, 1.5, false, "مستوي مايل", "مستوي", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?مستوي\\s+(?:ال)?مايل(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(1, 1.5, false, "inclined plane", "inclined", false, false, JSRegex("(?:^|[^a-z0-9])inclined\\s+plane(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(1, 1.5, false, "pulley", "pulley", false, false, JSRegex("(?:^|[^a-z0-9])pulley(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(1, 1.5, false, "مقذوف", "مقذوف", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?مقذوف(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(1, 1.5, false, "projectile", "projectile", false, false, JSRegex("(?:^|[^a-z0-9])projectile(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(1, 1.5, false, "statics", "statics", false, false, JSRegex("(?:^|[^a-z0-9])statics(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(1, 1.5, false, "زخم زاوي", "زخم", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?زخم\\s+(?:ال)?زاوي(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(1, 1.5, false, "angular momentum", "angular", false, false, JSRegex("(?:^|[^a-z0-9])angular\\s+momentum(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(1, 1.5, false, "ديناميكا حراريه", "ديناميكا", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?ديناميكا\\s+(?:ال)?حراري(?:ه|ت)(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(1, 1.5, false, "thermodynamics", "thermodynamics", false, false, JSRegex("(?:^|[^a-z0-9])thermodynamics(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(1, 1.5, false, "قصور ذاتي", "قصور", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?قصور\\s+(?:ال)?ذاتي(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(1, 1.5, false, "inertia", "inertia", false, false, JSRegex("(?:^|[^a-z0-9])inertia(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(1, 1.5, false, "شد الخيط", "شد", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?شد\\s+(?:ال)?الخيط(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(1, 1.5, false, "قوه الطرد المركزي", "قو", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?قو(?:ه|ت)\\s+(?:ال)?الطرد\\s+(?:ال)?المركزي(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(1, 1.2, false, "موجات", "موجات", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?موجات(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(1, 1.2, false, "امواج", "امواج", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?امواج(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(1, 1.2, false, "تردد", "تردد", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?تردد(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(1, 1.2, false, "قذيفه", "قذيف", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?قذيف(?:ه|ت)(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(1, 1.2, false, "بكره", "بكر", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?بكر(?:ه|ت)(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(1, 1.2, false, "تصادم", "تصادم", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?تصادم(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(1, 1.2, false, "collision", "collision", false, false, JSRegex("(?:^|[^a-z0-9])collision(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(1, 1.2, false, "ازاحه", "ازاح", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?ازاح(?:ه|ت)(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(1, 1.2, false, "displacement", "displacement", false, false, JSRegex("(?:^|[^a-z0-9])displacement(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(1, 1.2, false, "كهربايي", "كهربايي", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?كهربايي(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(1, 1.2, false, "ديناميك", "ديناميك", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?ديناميك(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(1, 1.2, false, "dynamics", "dynamics", false, false, JSRegex("(?:^|[^a-z0-9])dynamics(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(1, 1.2, false, "نصف عمر", "نصف", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?نصف\\s+(?:ال)?عمر(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(1, 1.2, false, "half life", "half", false, false, JSRegex("(?:^|[^a-z0-9])half\\s+life(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(1, 1.2, false, "مرايا", "مرايا", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?مرايا(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(1, 1.2, false, "موشور", "موشور", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?موشور(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(1, 1.2, false, "prism", "prism", false, false, JSRegex("(?:^|[^a-z0-9])prism(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(1, 1.0, false, "resistance", "resistance", false, false, JSRegex("(?:^|[^a-z0-9])resistance(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(1, 1.0, false, "اوم", "اوم", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?اوم(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(1, 1.0, false, "ohm", "ohm", false, false, JSRegex("(?:^|[^a-z0-9])ohm(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(1, 1.0, false, "wave", "wave", false, false, JSRegex("(?:^|[^a-z0-9])wave(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(1, 1.0, false, "frequency", "frequency", false, false, JSRegex("(?:^|[^a-z0-9])frequency(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(1, 1.0, false, "resonance", "resonance", false, false, JSRegex("(?:^|[^a-z0-9])resonance(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(1, 1.0, false, "سرعه", "سرع", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?سرع(?:ه|ت)(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(1, 1.0, false, "angular", "angular", false, false, JSRegex("(?:^|[^a-z0-9])angular(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(1, 1.0, false, "عزم", "عزم", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?عزم(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(1, 1.0, false, "اهتزاز", "اهتزاز", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?اهتزاز(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(1, 0.6, false, "شغل", "شغل", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?شغل(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(1, 0.6, false, "قدره", "قدر", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?قدر(?:ه|ت)(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(1, 0.6, false, "جهد", "جهد", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?جهد(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(1, 0.6, false, "قوي", "قوي", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?قوي(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(1, 0.6, false, "قوه", "قو", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?قو(?:ه|ت)(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(1, 0.6, false, "وزن", "وزن", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?وزن(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(1, 0.6, false, "حركه", "حرك", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?حرك(?:ه|ت)(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(1, 0.6, false, "motion", "motion", false, false, JSRegex("(?:^|[^a-z0-9])motion(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(1, 0.6, false, "دوران", "دوران", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?دوران(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(1, 0.6, false, "ملف", "ملف", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?ملف(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(1, 0.6, false, "عجله", "عجل", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?عجل(?:ه|ت)(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(1, 0.6, false, "جول", "جول", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?جول(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(1, 0.6, false, "مرن", "مرن", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?مرن(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(1, 0.6, false, "elastic", "elastic", false, false, JSRegex("(?:^|[^a-z0-9])elastic(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(1, 0.6, false, "تيار", "تيار", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?تيار(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(1, 0.6, false, "مقاومه", "مقاوم", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?مقاوم(?:ه|ت)(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(1, 0.6, false, "انعكاس", "انعكاس", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?انعكاس(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(1, 0.6, false, "تداخل", "تداخل", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?تداخل(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(1, 0.6, false, "interference", "interference", false, false, JSRegex("(?:^|[^a-z0-9])interference(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(1, 0.6, false, "رنين", "رنين", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?رنين(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(1, 0.6, false, "اندماج", "اندماج", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?اندماج(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(1, 1.0, true, "ذره", "ذر", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?ذر(?:ه|ت)(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(1, 1.0, true, "atom", "atom", false, false, JSRegex("(?:^|[^a-z0-9])atom(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(1, 1.0, true, "الكترون", "الكترون", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?الكترون(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(1, 1.0, true, "electron", "electron", false, false, JSRegex("(?:^|[^a-z0-9])electron(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(1, 1.0, true, "نواه", "نوا", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?نوا(?:ه|ت)(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(1, 1.0, true, "nucleus", "nucleus", false, false, JSRegex("(?:^|[^a-z0-9])nucleus(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(1, 1.0, true, "اشعاع", "اشعاع", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?اشعاع(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(1, 1.0, true, "radiation", "radiation", false, false, JSRegex("(?:^|[^a-z0-9])radiation(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(1, 1.0, true, "اتزان", "اتزان", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?اتزان(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(1, 1.0, true, "equilibrium", "equilibrium", false, false, JSRegex("(?:^|[^a-z0-9])equilibrium(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(1, 1.0, true, "نظاير", "نظاير", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?نظاير(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(1, 1.0, true, "isotope", "isotope", false, false, JSRegex("(?:^|[^a-z0-9])isotope(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(1, 1.0, true, "انتروبي", "انتروبي", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?انتروبي(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(1, 1.0, true, "entropy", "entropy", false, false, JSRegex("(?:^|[^a-z0-9])entropy(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(1, 0.6, true, "طاقه", "طاق", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?طاق(?:ه|ت)(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(1, 0.6, true, "energy", "energy", false, false, JSRegex("(?:^|[^a-z0-9])energy(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(1, 0.6, true, "حراره", "حرار", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?حرار(?:ه|ت)(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(1, 0.6, true, "heat", "heat", false, false, JSRegex("(?:^|[^a-z0-9])heat(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(1, 0.6, true, "ضغط", "ضغط", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?ضغط(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(1, 0.6, true, "pressure", "pressure", false, false, JSRegex("(?:^|[^a-z0-9])pressure(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(1, 0.6, true, "كثافه", "كثاف", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?كثاف(?:ه|ت)(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(1, 0.6, true, "density", "density", false, false, JSRegex("(?:^|[^a-z0-9])density(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(1, 0.6, true, "كتله", "كتل", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?كتل(?:ه|ت)(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(1, 0.6, true, "mass", "mass", false, false, JSRegex("(?:^|[^a-z0-9])mass(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(1, 0.6, true, "درجه الحراره", "درج", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?درج(?:ه|ت)\\s+(?:ال)?الحرار(?:ه|ت)(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(1, 0.6, true, "temperature", "temperature", false, false, JSRegex("(?:^|[^a-z0-9])temperature(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(2, 2.0, false, "كيميا", "كيميا", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?كيميا(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(2, 2.0, false, "كيميايي", "كيميايي", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?كيميايي(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(2, 2.0, false, "chemistry", "chemistry", false, false, JSRegex("(?:^|[^a-z0-9])chemistry(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(2, 2.0, false, "جدول دوري", "جدول", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?جدول\\s+(?:ال)?دوري(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(2, 2.0, false, "periodic table", "periodic", false, false, JSRegex("(?:^|[^a-z0-9])periodic\\s+table(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(2, 1.5, false, "molar", "molar", false, false, JSRegex("(?:^|[^a-z0-9])molar(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(2, 1.5, false, "mole", "mole", false, false, JSRegex("(?:^|[^a-z0-9])mole(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(2, 1.5, false, "مولاريه", "مولاري", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?مولاري(?:ه|ت)(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(2, 1.5, false, "molarity", "molarity", false, false, JSRegex("(?:^|[^a-z0-9])molarity(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(2, 1.5, false, "تكافو", "تكافو", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?تكافو(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(2, 1.5, false, "valence", "valence", false, false, JSRegex("(?:^|[^a-z0-9])valence(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(2, 1.5, false, "valency", "valency", false, false, JSRegex("(?:^|[^a-z0-9])valency(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(2, 1.5, false, "stoichiometry", "stoichiometry", false, false, JSRegex("(?:^|[^a-z0-9])stoichiometry(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(2, 1.5, false, "ستوكيومتري", "ستوكيومتري", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?ستوكيومتري(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(2, 1.5, false, "حمض", "حمض", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?حمض(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(2, 1.5, false, "acid", "acid", false, false, JSRegex("(?:^|[^a-z0-9])acid(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(2, 1.5, false, "قلوي", "قلوي", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?قلوي(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(2, 1.5, false, "alkaline", "alkaline", false, false, JSRegex("(?:^|[^a-z0-9])alkaline(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(2, 1.5, false, "alkali", "alkali", false, false, JSRegex("(?:^|[^a-z0-9])alkali(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(2, 1.5, false, "ph", "ph", false, false, JSRegex("(?:^|[^a-z0-9])ph(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(2, 1.5, false, "تسحيح", "تسحيح", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?تسحيح(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(2, 1.5, false, "titration", "titration", false, false, JSRegex("(?:^|[^a-z0-9])titration(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(2, 1.5, false, "اكسده", "اكسد", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?اكسد(?:ه|ت)(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(2, 1.5, false, "oxidation", "oxidation", false, false, JSRegex("(?:^|[^a-z0-9])oxidation(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(2, 1.5, false, "اختزال", "اختزال", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?اختزال(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(2, 1.5, false, "redox", "redox", false, false, JSRegex("(?:^|[^a-z0-9])redox(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(2, 1.5, false, "تاكسد", "تاكسد", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?تاكسد(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(2, 1.5, false, "موكسد", "موكسد", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?موكسد(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(2, 1.5, false, "oxidizing", "oxidizing", false, false, JSRegex("(?:^|[^a-z0-9])oxidizing(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(2, 1.5, false, "متفاعلات", "متفاعلات", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?متفاعلات(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(2, 1.5, false, "reactant", "reactant", false, false, JSRegex("(?:^|[^a-z0-9])reactant(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(2, 1.5, false, "الكان", "الكان", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?الكان(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(2, 1.5, false, "alkane", "alkane", false, false, JSRegex("(?:^|[^a-z0-9])alkane(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(2, 1.5, false, "الكين", "الكين", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?الكين(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(2, 1.5, false, "alkene", "alkene", false, false, JSRegex("(?:^|[^a-z0-9])alkene(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(2, 1.5, false, "الكاين", "الكاين", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?الكاين(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(2, 1.5, false, "alkyne", "alkyne", false, false, JSRegex("(?:^|[^a-z0-9])alkyne(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(2, 1.5, false, "benzene", "benzene", false, false, JSRegex("(?:^|[^a-z0-9])benzene(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(2, 1.5, false, "الديهايد", "الديهايد", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?الديهايد(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(2, 1.5, false, "aldehyde", "aldehyde", false, false, JSRegex("(?:^|[^a-z0-9])aldehyde(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(2, 1.5, false, "كيتون", "كيتون", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?كيتون(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(2, 1.5, false, "ketone", "ketone", false, false, JSRegex("(?:^|[^a-z0-9])ketone(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(2, 1.5, false, "هيدروكربون", "هيدروكربون", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?هيدروكربون(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(2, 1.5, false, "hydrocarbon", "hydrocarbon", false, false, JSRegex("(?:^|[^a-z0-9])hydrocarbon(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(2, 1.5, false, "جزيء", "جزيء", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?جزيء(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(2, 1.5, false, "molecule", "molecule", false, false, JSRegex("(?:^|[^a-z0-9])molecule(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(2, 1.5, false, "جزييات", "جزييات", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?جزييات(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(2, 1.5, false, "ايوني", "ايوني", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?ايوني(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(2, 1.5, false, "ionic", "ionic", false, false, JSRegex("(?:^|[^a-z0-9])ionic(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(2, 1.5, false, "تساهمي", "تساهمي", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?تساهمي(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(2, 1.5, false, "covalent", "covalent", false, false, JSRegex("(?:^|[^a-z0-9])covalent(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(2, 1.5, false, "محاليل", "محاليل", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?محاليل(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(2, 1.5, false, "مذيب", "مذيب", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?مذيب(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(2, 1.5, false, "solvent", "solvent", false, false, JSRegex("(?:^|[^a-z0-9])solvent(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(2, 1.5, false, "مذاب", "مذاب", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?مذاب(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(2, 1.5, false, "solute", "solute", false, false, JSRegex("(?:^|[^a-z0-9])solute(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(2, 1.5, false, "ذايبيه", "ذايبي", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?ذايبي(?:ه|ت)(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(2, 1.5, false, "solubility", "solubility", false, false, JSRegex("(?:^|[^a-z0-9])solubility(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(2, 1.5, false, "ثابت الاتزان", "ثابت", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?ثابت\\s+(?:ال)?الاتزان(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(2, 1.5, false, "انثالبي", "انثالبي", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?انثالبي(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(2, 1.5, false, "enthalpy", "enthalpy", false, false, JSRegex("(?:^|[^a-z0-9])enthalpy(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(2, 1.5, false, "حفاز", "حفاز", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?حفاز(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(2, 1.5, false, "catalyst", "catalyst", false, false, JSRegex("(?:^|[^a-z0-9])catalyst(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(2, 1.5, false, "افوجادرو", "افوجادرو", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?افوجادرو(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(2, 1.5, false, "avogadro", "avogadro", false, false, JSRegex("(?:^|[^a-z0-9])avogadro(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(2, 1.5, false, "صيغه جزيييه", "صيغ", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?صيغ(?:ه|ت)\\s+(?:ال)?جزييي(?:ه|ت)(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(2, 1.5, false, "molecular formula", "molecular", false, false, JSRegex("(?:^|[^a-z0-9])molecular\\s+formula(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(2, 1.5, false, "كتله موليه", "كتل", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?كتل(?:ه|ت)\\s+(?:ال)?مولي(?:ه|ت)(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(2, 1.5, false, "molar mass", "molar", false, false, JSRegex("(?:^|[^a-z0-9])molar\\s+mass(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(2, 1.5, false, "غاز مثالي", "غاز", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?غاز\\s+(?:ال)?مثالي(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(2, 1.5, false, "ideal gas", "ideal", false, false, JSRegex("(?:^|[^a-z0-9])ideal\\s+gas(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(2, 1.5, false, "تحليل كهربايي", "تحليل", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?تحليل\\s+(?:ال)?كهربايي(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(2, 1.5, false, "electrolysis", "electrolysis", false, false, JSRegex("(?:^|[^a-z0-9])electrolysis(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(2, 1.5, false, "توزيع الكتروني", "توزيع", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?توزيع\\s+(?:ال)?الكتروني(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(2, 1.5, false, "electron configuration", "electron", false, false, JSRegex("(?:^|[^a-z0-9])electron\\s+configuration(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(2, 1.5, false, "محلول منظم", "محلول", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?محلول\\s+(?:ال)?منظم(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(2, 1.5, false, "رقم هيدروجيني", "رقم", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?رقم\\s+(?:ال)?هيدروجيني(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(2, 1.5, false, "هيدروكسيد", "هيدروكسيد", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?هيدروكسيد(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(2, 1.5, false, "كبريتيك", "كبريتيك", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?كبريتيك(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(2, 1.2, false, "مولات", "مولات", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?مولات(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(2, 1.2, false, "معايره", "معاير", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?معاير(?:ه|ت)(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(2, 1.2, false, "ايون", "ايون", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?ايون(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(2, 1.2, false, "ion", "ion", false, false, JSRegex("(?:^|[^a-z0-9])ion(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(2, 1.2, false, "organic", "organic", false, false, JSRegex("(?:^|[^a-z0-9])organic(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(2, 1.2, false, "استر", "استر", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?استر(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(2, 1.2, false, "ester", "ester", false, false, JSRegex("(?:^|[^a-z0-9])ester(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(2, 1.2, false, "بوليمر", "بوليمر", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?بوليمر(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(2, 1.2, false, "polymer", "polymer", false, false, JSRegex("(?:^|[^a-z0-9])polymer(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(2, 1.2, false, "ترسيب", "ترسيب", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?ترسيب(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(2, 1.2, false, "precipitate", "precipitate", false, false, JSRegex("(?:^|[^a-z0-9])precipitate(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(2, 1.2, false, "محفز", "محفز", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?محفز(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(2, 1.2, false, "chemical", "chemical", false, false, JSRegex("(?:^|[^a-z0-9])chemical(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(2, 1.2, false, "احتراق", "احتراق", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?احتراق(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(2, 1.2, false, "combustion", "combustion", false, false, JSRegex("(?:^|[^a-z0-9])combustion(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(2, 1.2, false, "كلوريد", "كلوريد", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?كلوريد(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(2, 1.2, false, "نترات", "نترات", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?نترات(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(2, 1.2, false, "كربونات", "كربونات", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?كربونات(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(2, 1.2, false, "اكسيد", "اكسيد", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?اكسيد(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(2, 1.2, false, "محلول", "محلول", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?محلول(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(2, 0.6, false, "قاعده", "قاعد", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?قاعد(?:ه|ت)(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(2, 0.6, false, "قواعد", "قواعد", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?قواعد(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(2, 0.6, false, "base", "base", false, false, JSRegex("(?:^|[^a-z0-9])base(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(2, 0.6, false, "عضويه", "عضوي", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?عضوي(?:ه|ت)(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(2, 0.6, false, "تعادل", "تعادل", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?تعادل(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(2, 0.6, false, "alcohol", "alcohol", false, false, JSRegex("(?:^|[^a-z0-9])alcohol(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(2, 0.6, false, "كحول", "كحول", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?كحول(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(2, 0.6, false, "reduction", "reduction", false, false, JSRegex("(?:^|[^a-z0-9])reduction(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(2, 0.6, false, "buffer", "buffer", false, false, JSRegex("(?:^|[^a-z0-9])buffer(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(2, 0.6, false, "عنصر", "عنصر", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?عنصر(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(2, 0.6, false, "element", "element", false, false, JSRegex("(?:^|[^a-z0-9])element(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(2, 0.6, false, "مركب", "مركب", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?مركب(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(2, 0.6, false, "compound", "compound", false, false, JSRegex("(?:^|[^a-z0-9])compound(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(2, 0.6, false, "رابطه", "رابط", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?رابط(?:ه|ت)(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(2, 0.6, false, "bond", "bond", false, false, JSRegex("(?:^|[^a-z0-9])bond(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(2, 0.6, false, "تركيز", "تركيز", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?تركيز(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(2, 0.6, false, "concentration", "concentration", false, false, JSRegex("(?:^|[^a-z0-9])concentration(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(2, 0.6, false, "نواتج", "نواتج", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?نواتج(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(2, 0.6, false, "مول", "مول", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?مول(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(2, 0.6, false, "بنزين", "بنزين", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?بنزين(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(2, 0.6, false, "راسب", "راسب", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?راسب(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(2, 0.6, false, "اكسجين", "اكسجين", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?اكسجين(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(2, 0.6, false, "اوكسجين", "اوكسجين", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?اوكسجين(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(2, 1.0, true, "تفاعل", "تفاعل", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?تفاعل(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(2, 1.0, true, "reaction", "reaction", false, false, JSRegex("(?:^|[^a-z0-9])reaction(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(2, 1.0, true, "ذره", "ذر", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?ذر(?:ه|ت)(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(2, 1.0, true, "atom", "atom", false, false, JSRegex("(?:^|[^a-z0-9])atom(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(2, 1.0, true, "الكترون", "الكترون", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?الكترون(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(2, 1.0, true, "electron", "electron", false, false, JSRegex("(?:^|[^a-z0-9])electron(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(2, 1.0, true, "نواه", "نوا", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?نوا(?:ه|ت)(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(2, 1.0, true, "nucleus", "nucleus", false, false, JSRegex("(?:^|[^a-z0-9])nucleus(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(2, 1.0, true, "اشعاع", "اشعاع", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?اشعاع(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(2, 1.0, true, "radiation", "radiation", false, false, JSRegex("(?:^|[^a-z0-9])radiation(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(2, 1.0, true, "اتزان", "اتزان", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?اتزان(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(2, 1.0, true, "equilibrium", "equilibrium", false, false, JSRegex("(?:^|[^a-z0-9])equilibrium(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(2, 1.0, true, "نظاير", "نظاير", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?نظاير(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(2, 1.0, true, "isotope", "isotope", false, false, JSRegex("(?:^|[^a-z0-9])isotope(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(2, 1.0, true, "انتروبي", "انتروبي", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?انتروبي(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(2, 1.0, true, "entropy", "entropy", false, false, JSRegex("(?:^|[^a-z0-9])entropy(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(2, 0.6, true, "طاقه", "طاق", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?طاق(?:ه|ت)(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(2, 0.6, true, "energy", "energy", false, false, JSRegex("(?:^|[^a-z0-9])energy(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(2, 0.6, true, "حراره", "حرار", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?حرار(?:ه|ت)(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(2, 0.6, true, "heat", "heat", false, false, JSRegex("(?:^|[^a-z0-9])heat(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(2, 0.6, true, "ضغط", "ضغط", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?ضغط(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(2, 0.6, true, "pressure", "pressure", false, false, JSRegex("(?:^|[^a-z0-9])pressure(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(2, 0.6, true, "كثافه", "كثاف", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?كثاف(?:ه|ت)(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(2, 0.6, true, "density", "density", false, false, JSRegex("(?:^|[^a-z0-9])density(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(2, 0.6, true, "كتله", "كتل", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?كتل(?:ه|ت)(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(2, 0.6, true, "mass", "mass", false, false, JSRegex("(?:^|[^a-z0-9])mass(?:s|es)?(?![a-z0-9])", true)),
        LexEntry(2, 0.6, true, "درجه الحراره", "درج", true, false, JSRegex("(?:^|[^ء-ي])(?:وال|فال|بال|كال|لل|ال|و|ف|ب|ك|ل)?درج(?:ه|ت)\\s+(?:ال)?الحرار(?:ه|ت)(?:ات|يات|يه|ين|ون|ها|هم|هما|كم|نا|ه|ي|ك|ا|ء)?(?![ء-ي])", false)),
        LexEntry(2, 0.6, true, "temperature", "temperature", false, false, JSRegex("(?:^|[^a-z0-9])temperature(?:s|es)?(?![a-z0-9])", true)),
    ]
    private static let baseTemplate = " DIFFICULTY LEVEL FOR THIS CONVERSATION — LEVEL @@LEVEL@@ OF 7, \"@@NAME@@\". This is a persistent setting attached to this chat, not a passing mood. It governs EVERY question, problem, exercise, exam, worksheet or practice set you generate in this reply; if this reply contains none, it changes nothing. It OVERRIDES every earlier sentence in this system message about how hard generated work should be by default — including the hard-by-default rule: at a low level an easy set is the CORRECT output and a hard one is a FAILURE. If the user's own stated requirements for this turn name a difficulty, THOSE outrank this level. LEVEL @@LEVEL@@ — \"@@NAME@@\" — MEANS EXACTLY THIS, and every item you write must satisfy every clause: @@SPEC@@ NEVER buy difficulty with longer arithmetic, larger numbers, more decimal places, more sub-parts of the same kind, or vaguer wording, and never sell it by explaining less: difficulty is set by the properties above and by nothing else. Every item must remain valid, well-posed and cleanly solvable, and you must solve it privately before you publish it. Do NOT mention this level, these properties, or any rung number in your reply unless a sentence below tells you to."
    private static let upTemplate = " THE LEVEL JUST MOVED, ON THIS MESSAGE. The user asked for HARDER work, by @@DEGREE@@. PREVIOUS LEVEL: @@PREVIOUS@@ — \"@@PREVIOUS_NAME@@\". NEW LEVEL: @@LEVEL@@ — \"@@NAME@@\". These are the facets that changed, and the new set must differ from the previous one in EVERY one of them: @@DELTA@@. Do not re-roll at your own default and do not make a cosmetic change: different constants, renamed variables, a longer statement or an extra sub-part of the same kind are NOT a change of level. None of the new items may be a re-skin of anything you already gave in this conversation. HARDER IS A REAL DIRECTION TOO: more concepts that must MEET, more steps where the solver has to choose rather than execute, and a move that is not the first one anybody thinks of."
    private static let downTemplate = " THE LEVEL JUST MOVED, ON THIS MESSAGE. The user asked for EASIER work, by @@DEGREE@@. PREVIOUS LEVEL: @@PREVIOUS@@ — \"@@PREVIOUS_NAME@@\". NEW LEVEL: @@LEVEL@@ — \"@@NAME@@\". These are the facets that changed, and the new set must differ from the previous one in EVERY one of them: @@DELTA@@. Do not re-roll at your own default and do not make a cosmetic change: different constants, renamed variables, a longer statement or an extra sub-part of the same kind are NOT a change of level. None of the new items may be a re-skin of anything you already gave in this conversation. EASIER IS A REAL DIRECTION, NOT LESS TEXT: combine fewer concepts, use the direct standard method, drop the non-obvious move, remove the trap and the limiting case, and choose numbers whose arithmetic is clean. The SOLUTION stays complete and fully worked — it is the PROBLEM that gets simpler, never the explanation."
    private static let topTemplate = " THE USER JUST ASKED FOR SOMETHING HARDER AND THE LADDER IS ALREADY AT ITS TOP RUNG (7 of 7). Do not pretend to move and do not quietly ignore them: stay at level 7, make this set genuinely NEW and no easier than the last, and OPEN your reply with ONE short sentence, in the user's language, saying they are already at the highest level and that this is a fresh set at it."
    private static let bottomTemplate = " THE USER JUST ASKED FOR SOMETHING EASIER AND THE LADDER IS ALREADY AT ITS LOWEST RUNG (1 of 7). Do not pretend to move and do not quietly ignore them: stay at level 1, make this set genuinely NEW and no harder than the last, and OPEN your reply with ONE short sentence, in the user's language, saying they are already at the easiest level and that this is a fresh set at it."
    private static let directTemplate = " THE LEVEL JUST MOVED, ON THIS MESSAGE. The user asked for EASIER work, by @@DEGREE@@. PREVIOUS LEVEL: @@PREVIOUS@@ — \"@@PREVIOUS_NAME@@\". NEW LEVEL: @@LEVEL@@ — \"@@NAME@@\". These are the facets that changed, and the new set must differ from the previous one in EVERY one of them: @@DELTA@@. Do not re-roll at your own default and do not make a cosmetic change: different constants, renamed variables, a longer statement or an extra sub-part of the same kind are NOT a change of level. None of the new items may be a re-skin of anything you already gave in this conversation. HARDER IS A REAL DIRECTION TOO: more concepts that must MEET, more steps where the solver has to choose rather than execute, and a move that is not the first one anybody thinks of."
}
