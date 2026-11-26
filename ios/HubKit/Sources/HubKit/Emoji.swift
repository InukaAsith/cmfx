import Foundation

/// Emoji as text the watch can draw: the common ones as their text faces, the rest as `*`.
public enum Emoji {
    static let faces: [Unicode.Scalar: String] = {
        let pairs: [(String, String)] = [
            ("😀😃😄😁😆😊☺🙂😸", ":)"), ("😂🤣😹", "XD"), ("😅", "^^;"), ("😉😜", ";)"), ("😛😝😋", ":P"),
            ("😍🥰😘😻", ":*"), ("😎", "B)"), ("😢😥😿🥲", ":'("), ("😭", "T_T"), ("🙁☹😞😔😟😕", ":("),
            ("😮😯😲😱🙀", ":O"), ("😐😑😶", ":|"), ("😡😠🤬", ">:("), ("🤔", "(hmm)"), ("😴", "zzz"),
            ("🙄", "(eyeroll)"), ("😳", "o_o"), ("🤗", "(hug)"), ("🤷", "(shrug)"), ("🤦", "(facepalm)"),
            ("❤♥💖💗💕💞💓💘💝🧡💛💚💙💜🖤🤍🤎😇", "<3"), ("💔", "</3"), ("👍", "(y)"), ("👎", "(n)"),
            ("👌", "(ok)"), ("🙏", "(pray)"), ("👏", "(clap)"), ("👋", "(wave)"), ("💪", "(strong)"),
            ("✌", "(v)"), ("🤞", "(fingers crossed)"), ("🔥", "(fire)"), ("🎉🥳🎊", "(party)"), ("🎂", "(cake)"),
            ("✅✔☑", "(done)"), ("❌✖", "(x)"), ("⭐🌟", "(star)"), ("💯", "(100)"), ("👀", "(eyes)"),
            ("🌹🌸💐", "(flower)"), ("☀🌞", "(sun)"), ("🌙", "(moon)"), ("⚡", "(zap)"), ("💤", "zzz"),
            ("🤝", "(deal)"), ("🙌", "(yay)"), ("😬", ":S"), ("🤪", "XP"), ("🥺", "(please)"), ("😤", "(huff)"),
        ]
        var m: [Unicode.Scalar: String] = [:]
        for (list, text) in pairs { for u in list.unicodeScalars where u.value > 0xFF { m[u] = text } }
        return m
    }()

    /// Each emoji (with its skin tone, joiners and variation) as text; other characters as they are.
    public static func text(_ s: String) -> String {
        guard s.unicodeScalars.contains(where: { $0.value >= 0x2000 && $0.properties.isEmoji }) else { return s }
        var out = ""
        for ch in s {
            let us = ch.unicodeScalars
            guard let first = us.first, isEmoji(ch) else { out.append(ch); continue }
            if let t = faces[first] { out += t } else if (0x1F1E6...0x1F1FF).contains(first.value) { out += "(flag)" }
            else { out += "*" }
        }
        return out
    }

    /// Each emoji as its first code point (skin tone, joiners, variation and a flag's second letter dropped): the
    /// chats apps draw the watch's own 52 emoji and a box for the rest, one per emoji.
    public static func watch(_ s: String) -> String {
        guard s.unicodeScalars.contains(where: { $0.value >= 0x2000 && $0.properties.isEmoji }) else { return s }
        var out = ""
        for ch in s {
            guard let first = ch.unicodeScalars.first, isEmoji(ch) else { out.append(ch); continue }
            out.unicodeScalars.append(first)
        }
        return out
    }

    private static func isEmoji(_ ch: Character) -> Bool {
        let us = ch.unicodeScalars
        guard let first = us.first, first.value >= 0x2000 else { return false } // digits, #, *, ©: text
        return first.properties.isEmojiPresentation || (first.properties.isEmoji && us.contains { $0.value == 0xFE0F })
            || faces[first] != nil && first.properties.isEmoji
    }
}
