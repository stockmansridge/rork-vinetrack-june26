import Foundation

/// Readable case for a SHOUTED chemical product name.
///
/// # Why this exists on the client at all
///
/// The rule lives in the database — `public.vt_display_chemical_name(text)`
/// (sql/205) — and a trigger on `saved_chemicals` applies it to every write
/// from every client, so nothing here is load-bearing for what gets STORED.
///
/// What it buys is that VineTrack is offline-first: a chemical saved in the
/// shed is read straight back out of the local store, long before it reaches
/// Supabase. Without the same rule here the operator would watch a product go
/// in as `DITHANE RAINSHIELD NEO TEC FUNGICIDE` and quietly re-case itself
/// after the next sync. So this is a byte-for-byte mirror of the SQL function,
/// and the two must be changed together — the SQL is the source of truth and
/// `ChemicalDisplayNameTests` pins both to the same fixtures.
///
/// # The rule
///
/// A name that already contains ANY lower-case letter is returned untouched.
/// That one guard is the whole safety of this: a manufacturer's own styling
/// (`Kocide Blue Xtra`) or wording the operator deliberately typed can never
/// be re-cased.
///
/// Within a shouted name each word is capitalised, except where the capitals
/// carry meaning: anything containing a digit (`500SC`), single characters
/// (the `D` of `2,4-D`), words with no vowel (`WG`, `SC`, `EC`, `MZ`) and a
/// short list of vowel-carrying codes (`ULV`, `MCPA`). Hyphenated words are
/// cased part by part.
nonisolated enum ChemicalDisplayName {

    /// Vowel-carrying tokens that are codes, not words. Anything WITHOUT a
    /// vowel is already covered by the general rule, so this only holds the
    /// exceptions to it. Mirrors `keep_upper` in sql/205.
    private static let keepUpper: Set<String> = [
        "ULV", "RTU", "ME", "EW", "OD", "GR", "UL", "EG", "SE", "ZC", "AF",
        "MCPA", "NPK", "IPM", "II", "III"
    ]

    private static let vowels: Set<Character> = ["A", "E", "I", "O", "U", "Y"]

    /// The same product name, in the case a person would write it.
    ///
    /// Returns the input unchanged unless it is entirely capitals.
    static func cased(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return raw }
        // Already carries lower case: cased by a human or a manufacturer.
        guard trimmed == trimmed.uppercased() else { return raw }

        return trimmed
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .map { word in
                word
                    .split(separator: "-", omittingEmptySubsequences: false)
                    .map { casedPart(String($0)) }
                    .joined(separator: "-")
            }
            .joined(separator: " ")
    }

    private static func casedPart(_ part: String) -> String {
        if part.isEmpty { return part }
        if part.contains(where: { $0.isNumber }) { return part }   // 500SC, 750DF, 2,4
        if part.count == 1 { return part }                          // the D of 2,4-D
        if keepUpper.contains(part) { return part }                 // ULV, MCPA
        if !part.contains(where: { vowels.contains($0) }) { return part } // WG, SC, EC, MZ
        return initcap(part)
    }

    /// Postgres `initcap`: upper-case the first character of every run of
    /// alphanumerics, lower-case the rest. Reimplemented rather than using
    /// `String.capitalized`, whose locale-aware word breaking does not agree
    /// with Postgres on apostrophes.
    private static func initcap(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        var atWordStart = true
        for character in text {
            if character.isLetter || character.isNumber {
                out.append(atWordStart ? Character(character.uppercased()) : Character(character.lowercased()))
                atWordStart = false
            } else {
                out.append(character)
                atWordStart = true
            }
        }
        return out
    }
}
