import Foundation

/// The ads a site puts in its own data (#741). YouTube's player is told what
/// to play by its page, or by a reply it asks for as you go from video to
/// video: the video, and beside it the ads before, during and after it, each
/// under a name of its own. They come from YouTube's own servers, so no name
/// or address tells them apart, and the lists (EasyList, EasyPrivacy) have no
/// rule for them. Those names are changed in the data as it passes, for others
/// of the same length that the player doesn't know, so it finds no ads;
/// everything else stays as the site sent it.
public enum AdSlots {
    struct Rule {
        /// Where it applies, and under each.
        let sites: [String]
        /// What's asked for that isn't a page, by how it starts.
        let dataPaths: [String]
        let names: [String]
    }

    static let rules = [
        Rule(sites: ["youtube.com", "youtube-nocookie.com"],
             dataPaths: ["/youtubei/v1/player", "/youtubei/v1/get_watch", "/youtubei/v1/reel/"],
             names: ["adPlacements", "adSlots", "playerAds"]),
    ]

    /// The names of the ad slots in what `target` (a request's path) gets
    /// from `host`: in any page there, as a video's own page has many
    /// addresses, or in the player's replies; none for nearly everything.
    public static func names(host: String, target: String, page: Bool) -> [String] {
        let host = host.lowercased()
        return rules.first { rule in
            rule.sites.contains { host == $0 || host.hasSuffix("." + $0) }
                && (page || rule.dataPaths.contains { target.hasPrefix($0) })
        }?.names ?? []
    }

    /// `data` with those names changed wherever they name something, or nil
    /// when none does. In JSON, in JSON inside a script's own text, or inside
    /// a string there (`\"` or `\x22` around it).
    public static func renamed(_ names: [String], in data: Data) -> Data? {
        var changed: [UInt8]?
        for name in names {
            let needle = Data(name.utf8)
            var from = data.startIndex
            while let found = data.range(of: needle, in: from..<data.endIndex) {
                from = found.upperBound
                guard isName(found, in: data) else { continue }
                if changed == nil { changed = [UInt8](data) }
                changed![found.lowerBound - data.startIndex] = UInt8(ascii: "_")
            }
        }
        return changed.map { Data($0) }
    }

    /// Whether what's there is a name: in quotes, with a colon after it.
    private static func isName(_ range: Range<Data.Index>, in data: Data) -> Bool {
        func ends(_ text: String) -> Bool {
            data[data.startIndex..<range.lowerBound].suffix(text.utf8.count).elementsEqual(text.utf8)
        }
        func starts(_ text: String, at index: Data.Index) -> Bool {
            data[index...].prefix(text.utf8.count).elementsEqual(text.utf8)
        }
        let quotes = ends("\\x22") ? ["\\x22"] : ends("\"") ? ["\"", "\\\""] : []
        guard let quote = quotes.first(where: { starts($0, at: range.upperBound) }) else { return false }
        var index = range.upperBound + quote.utf8.count
        while index < data.endIndex, data[index] == 0x20 { index += 1 }
        return starts(":", at: index) || starts("\\x3a", at: index)
    }
}
