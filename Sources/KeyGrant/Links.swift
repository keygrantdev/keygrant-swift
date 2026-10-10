import Foundation

// A payment link with a reference of this install's on it: `upgradeURL(paymentLink:)`'s, which names
// the activation an upgrade sale finds the key by.

/// The query parameter a payment link names its checkout's buyer by.
private let referenceName = "client_reference_id"

/// What JavaScript's `encodeURIComponent` leaves as it is.
private let uriComponentCharacters = CharacterSet(
    charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()"
)

/// A payment link's text when it is an absolute URL (a scheme, `:` and the rest, as `URL` reads
/// it), else nil: a path such as `/buy`, or a bare host such as `buy.stripe.com/x`, is not one.
func absoluteLink(_ link: URL) -> String? {
    let absolute = link.absoluteURL
    guard let scheme = absolute.scheme, !scheme.isEmpty else { return nil }
    return absolute.absoluteString
}

/// `link` with `reference` as its one `client_reference_id`, or nil when the link is not an
/// absolute URL (`absoluteLink`). Its query is edited as text (`referencedLinkText`).
func referencedLink(_ link: URL, _ reference: String) -> URL? {
    guard let text = absoluteLink(link) else { return nil }
    return URL(string: referencedLinkText(text, reference))
}

/// The text of an absolute link with `reference` as its one `client_reference_id`: every
/// parameter named exactly `client_reference_id` (its text before the first `=`, or all of it) and
/// every empty one left out, the others kept as written and in their order, and
/// `client_reference_id=<reference>` (percent-encoded as `encodeURIComponent` encodes) added last.
/// The fragment is kept after the query.
func referencedLinkText(_ text: String, _ reference: String) -> String {
    let hash = text.firstIndex(of: "#") ?? text.endIndex
    let beforeFragment = text[..<hash]
    let mark = beforeFragment.firstIndex(of: "?")
    let base = beforeFragment[..<(mark ?? beforeFragment.endIndex)]
    let query = mark.map { beforeFragment[beforeFragment.index(after: $0)...] } ?? ""
    // `split` leaves out the empty parts.
    let kept = query.split(separator: "&").filter { !sameText(String($0.prefix { $0 != "=" }), referenceName) }
    let encoded = reference.addingPercentEncoding(withAllowedCharacters: uriComponentCharacters) ?? reference
    let parts = kept.map(String.init) + ["\(referenceName)=\(encoded)"]
    return "\(base)?\(parts.joined(separator: "&"))\(text[hash...])"
}
