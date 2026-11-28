import Foundation

/// Resolves `cid:` references (RFC 2392) in an HTML body to inline `data:` URIs.
public enum InlineImages {
    /// Replaces every whole `cid:<id>` reference in `html` whose id matches an
    /// attachment's Content-ID with a `data:` URI of that attachment.
    /// The id ends at a delimiter (quote, `)`, `>`, whitespace, `;`, `,` or end), so
    /// `cid:image1` never matches inside `cid:image10`. The `cid:` scheme is matched
    /// case-insensitively; Content-IDs are compared without surrounding `<>`, also
    /// after percent-decoding the reference. Unknown references are left as they are.
    public static func resolve(_ html: String, attachments: [Attachment]) -> String {
        var byID: [String: Attachment] = [:]
        for a in attachments {
            guard let raw = a.contentID else { continue }
            let id = raw.trimmingCharacters(in: CharacterSet(charactersIn: "<> \t"))
            if !id.isEmpty, byID[id] == nil { byID[id] = a }
        }
        guard !byID.isEmpty else { return html }

        let chars = Array(html.unicodeScalars)
        let delimiters: Set<Unicode.Scalar> = ["\"", "'", ")", "(", "<", ">", ";", ",", "\\"]
        var out = String.UnicodeScalarView()
        var i = 0
        while i < chars.count {
            if i + 4 <= chars.count, isCIDScheme(chars, at: i),
               i == 0 || !isWordChar(chars[i - 1]) {
                var j = i + 4
                while j < chars.count, !delimiters.contains(chars[j]),
                      !CharacterSet.whitespacesAndNewlines.contains(chars[j]) {
                    j += 1
                }
                let ref = String(String.UnicodeScalarView(chars[(i + 4)..<j]))
                if let a = byID[ref] ?? ref.removingPercentEncoding.flatMap({ byID[$0] }) {
                    out.append(contentsOf: "data:\(a.mimeType);base64,\(a.data.base64EncodedString())".unicodeScalars)
                    i = j
                    continue
                }
            }
            out.append(chars[i])
            i += 1
        }
        return String(out)
    }

    private static func isCIDScheme(_ c: [Unicode.Scalar], at i: Int) -> Bool {
        (c[i] == "c" || c[i] == "C") && (c[i + 1] == "i" || c[i + 1] == "I")
            && (c[i + 2] == "d" || c[i + 2] == "D") && c[i + 3] == ":"
    }

    private static func isWordChar(_ s: Unicode.Scalar) -> Bool {
        CharacterSet.alphanumerics.contains(s) || s == "-" || s == "_" || s == "." || s == "+"
    }
}
