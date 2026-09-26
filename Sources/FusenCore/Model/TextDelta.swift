/// How much text changed between two versions, as characters removed and added. Found by trimming the
/// common prefix and suffix, so replacing text with text of the same length still shows up (a net
/// ± count would show 0).
struct TextDelta: Equatable {
    var removed: Int
    var added: Int

    static func between(_ old: String, _ new: String) -> TextDelta {
        let a = Array(old), b = Array(new)
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix,
              a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        return TextDelta(removed: a.count - prefix - suffix, added: b.count - prefix - suffix)
    }

    var summary: String {
        switch (removed, added) {
        case (0, 0): "変更なし"
        case (0, _): "+\(added)"
        case (_, 0): "−\(removed)"
        default: "−\(removed) +\(added)"
        }
    }
}
