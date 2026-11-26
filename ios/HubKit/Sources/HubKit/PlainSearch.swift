import Foundation

/// Web search without a browser, for the watch's Browser while the iPhone is locked (iOS stops web pages then, so
/// Google's results, which need their scripts, can't be read): result pages that come as plain HTML, read here.
/// Each gives rows of [title, url, snippet] for `BrowserProto.results`. Tried in turn: DuckDuckGo's HTML page, then
/// Wikipedia's search (an API: it always answers, but only with articles). (Bing and Brave were tried: Bing gives
/// unrelated results to a client without its cookies, Brave hides its links behind script redirects.)
public enum PlainSearch {
    public static func duckduckgo(_ q: String) -> URL { url("https://html.duckduckgo.com/html/", "q", q) }
    public static func wikipedia(_ q: String, lang: String = "en") -> URL {
        var c = URLComponents(string: "https://\(lang).wikipedia.org/w/api.php")!
        c.queryItems = [.init(name: "action", value: "opensearch"), .init(name: "search", value: q),
                        .init(name: "limit", value: "10"), .init(name: "format", value: "json")]
        return c.url!
    }

    static func url(_ base: String, _ key: String, _ q: String) -> URL {
        var c = URLComponents(string: base)!
        c.queryItems = [.init(name: key, value: q)]
        return c.url!
    }

    /// DuckDuckGo's results; empty for its bot check (or no results).
    public static func parseDuckDuckGo(_ html: String) -> [[String]] {
        var rows: [[String]] = []
        let titles = matches(#"<a[^>]*class="result__a"[^>]*href="([^"]+)"[^>]*>(.*?)</a>"#, html)
        let snippets = matches(#"class="result__snippet"[^>]*>(.*?)</(?:a|div|td)>"#, html).map { text($0[0]) }
        for (i, t) in titles.enumerated() {
            guard let u = ddgTarget(decode(t[0])) else { continue }
            rows.append([text(t[1]), u, i < snippets.count ? snippets[i] : ""])
        }
        return rows
    }

    /// `//duckduckgo.com/l/?uddg=<target>&rut=…` → the target.
    static func ddgTarget(_ href: String) -> String? {
        let h = href.hasPrefix("//") ? "https:" + href : href
        guard let c = URLComponents(string: h) else { return nil }
        if c.host?.hasSuffix("duckduckgo.com") == true {
            // an ad goes through y.js: left out
            guard c.path == "/l/", let u = c.queryItems?.first(where: { $0.name == "uddg" })?.value else { return nil }
            return u
        }
        return h.hasPrefix("http") ? h : nil
    }

    /// Wikipedia's opensearch: [query, [titles], [descriptions], [urls]].
    public static func parseWikipedia(_ json: Data) -> [[String]] {
        guard let a = try? JSONSerialization.jsonObject(with: json) as? [Any], a.count >= 4,
              let titles = a[1] as? [String], let urls = a[3] as? [String] else { return [] }
        let descs = a[2] as? [String] ?? []
        return titles.indices.compactMap { i in
            i < urls.count ? [titles[i] + " - Wikipedia", urls[i], i < descs.count ? descs[i] : ""] : nil
        }
    }

    // MARK: text

    static func matches(_ pattern: String, _ s: String) -> [[String]] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive])
        else { return [] }
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { m in
            (1..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) }
        }
    }

    /// Tags out, entities decoded, spaces collapsed.
    static func text(_ html: String) -> String {
        decode(html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression))
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    static func decode(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = s
        for (k, v) in [("&quot;", "\""), ("&#39;", "'"), ("&#x27;", "'"), ("&apos;", "'"), ("&lt;", "<"), ("&gt;", ">"),
                       ("&nbsp;", " "), ("&#183;", "·"), ("&middot;", "·")] {
            out = out.replacingOccurrences(of: k, with: v)
        }
        for m in matches("&#(x?)([0-9a-fA-F]+);", out).reversed() {
            if let n = UInt32(m[1], radix: m[0].isEmpty ? 10 : 16), let c = UnicodeScalar(n) {
                out = out.replacingOccurrences(of: "&#\(m[0])\(m[1]);", with: String(Character(c)))
            }
        }
        return out.replacingOccurrences(of: "&amp;", with: "&")
    }
}
