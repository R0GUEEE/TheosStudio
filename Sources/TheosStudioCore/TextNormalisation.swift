import Foundation

extension String {

    /// Normalises CRLF and lone CR line endings to LF.
    ///
    /// Swift treats `"\r\n"` as a *single* grapheme cluster, so
    /// `split(separator: "\n")` never matches a CRLF line ending at all: a
    /// control file written on another platform parses as one enormous field,
    /// with the value quietly containing the rest of the file. Every
    /// line-oriented parser here goes through this first.
    ///
    /// The `utf8.contains(13)` guard keeps the common (LF-only) path allocation
    /// free, which matters because this runs on every keystroke-length parse.
    func normalisedLineEndings() -> String {
        guard utf8.contains(13) else { return self }
        return replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }
}
