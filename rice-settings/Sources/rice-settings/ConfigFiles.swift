import Foundation

enum ConfigFileError: LocalizedError {
    case notFound(String)
    case badValue(String)
    /// A value the user typed or recorded that is not accepted; the text is the reason, shown as is.
    case rejected(String)

    var errorDescription: String? {
        switch self {
        case .notFound(let what): return "not found: \(what)"
        case .badValue(let what): return "invalid value: \(what)"
        case .rejected(let reason): return reason
        }
    }
}

/// A text config file edited line by line. Lines that are not touched are written back unchanged.
struct ConfigFile {
    let url: URL

    static let backupSuffix = ".bak-before-rice-settings"

    init(_ relativePath: String) {
        url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(relativePath)
    }

    /// Lines split on "\n"; a trailing newline gives a last empty element, so joining restores the file exactly.
    func readLines() throws -> [String] {
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.components(separatedBy: "\n")
    }

    /// Writes the lines back. Before the first write a backup copy is made next to the file;
    /// an existing backup is never overwritten, so it keeps the state from before rice-settings.
    func writeLines(_ lines: [String]) throws {
        let target = url.resolvingSymlinksInPath()
        let backup = URL(fileURLWithPath: target.path + Self.backupSuffix)
        if !FileManager.default.fileExists(atPath: backup.path) {
            try FileManager.default.copyItem(at: target, to: backup)
        }
        try lines.joined(separator: "\n").write(to: target, atomically: true, encoding: .utf8)
    }
}

private func regex(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
    // Patterns are fixed in this file, so a failure here is a programming error.
    return try! NSRegularExpression(pattern: pattern, options: options)
}

private func groups(_ re: NSRegularExpression, _ line: String) -> [String?]? {
    let ns = line as NSString
    guard let m = re.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
    return (0..<m.numberOfRanges).map { i in
        let r = m.range(at: i)
        return r.location == NSNotFound ? nil : ns.substring(with: r)
    }
}

// MARK: - kitty

/// Keys of ~/.config/kitty/kitty.conf in the form `key value`.
enum KittyConf {
    static let file = ConfigFile(".config/kitty/kitty.conf")
    static let keys = ["font_size", "font_family", "background_opacity", "cursor_shape"]

    /// Groups: 1 indent, 2 comment mark, 3 key, 4 separator, 5 value.
    private static func pattern(_ key: String) -> NSRegularExpression {
        let k = NSRegularExpression.escapedPattern(for: key)
        return regex("^(\\s*)(#\\s*)?(\(k))(\\s+)(\\S.*?)\\s*$")
    }

    /// The line that sets `key`: the last active line (kitty uses the last one),
    /// otherwise the first commented-out line. Lines like `#: key` are documentation and do not match.
    static func lineIndex(of key: String, in lines: [String]) -> Int? {
        let re = pattern(key)
        var active: Int?
        var commented: Int?
        for (i, line) in lines.enumerated() {
            guard let g = groups(re, line) else { continue }
            if g[2] == nil {
                active = i
            } else if commented == nil {
                commented = i
            }
        }
        return active ?? commented
    }

    /// Current value and whether the line is commented out; nil when the key is absent.
    static func read(_ key: String, in lines: [String]) -> (value: String, commented: Bool)? {
        guard let i = lineIndex(of: key, in: lines), let g = groups(pattern(key), lines[i]),
              let value = g[5] else { return nil }
        return (value, g[2] != nil)
    }

    /// Replaces the value of `key` in place (uncommenting the line if needed) or appends `key value`
    /// at the end of the file. Returns false when nothing had to change.
    @discardableResult
    static func write(_ key: String, _ value: String) throws -> Bool {
        guard keys.contains(key) else { throw ConfigFileError.badValue(key) }
        let v = value.trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty, !v.contains("\n"), !v.contains("\r") else { throw ConfigFileError.badValue(value) }
        var lines = try file.readLines()
        if let i = lineIndex(of: key, in: lines), let g = groups(pattern(key), lines[i]) {
            let newLine = (g[1] ?? "") + key + (g[4] ?? " ") + v
            if newLine == lines[i] { return false }
            lines[i] = newLine
        } else if let last = lines.last, last.isEmpty {
            lines.insert("\(key) \(v)", at: lines.count - 1)
        } else {
            lines.append("\(key) \(v)")
            lines.append("")
        }
        try file.writeLines(lines)
        return true
    }
}

// MARK: - kitty theme colours

/// Colour keys of ~/.config/kitty/current-theme.conf (the file kitty.conf includes) in the form `key #rrggbb`.
/// Only the hex of an existing active line is replaced: a missing key is never added and
/// commented-out lines (`# key ...`, `#: ...`) are never touched.
enum KittyTheme {
    static let file = ConfigFile(".config/kitty/current-theme.conf")
    static let keys: [String] = [
        "foreground", "background", "cursor", "cursor_text_color",
        "selection_foreground", "selection_background", "url_color",
        "active_border_color", "inactive_border_color",
        "active_tab_foreground", "active_tab_background",
        "inactive_tab_foreground", "inactive_tab_background",
    ] + (0...15).map { "color\($0)" }

    /// Groups: 1 indent, key and spacing; 2 the six hex digits; 3 the rest of the line (spaces, comment).
    /// The whitespace after the key keeps `color1` from matching `color10`.
    private static func pattern(_ key: String) -> NSRegularExpression {
        let k = NSRegularExpression.escapedPattern(for: key)
        return regex("^(\\s*\(k)\\s+)#([0-9a-fA-F]{6})(?![0-9a-zA-Z])(.*)$")
    }

    /// The active line that sets `key`; kitty uses the last one.
    static func lineIndex(of key: String, in lines: [String]) -> Int? {
        let re = pattern(key)
        var found: Int?
        for (i, line) in lines.enumerated() where groups(re, line) != nil {
            found = i
        }
        return found
    }

    /// The six hex digits without "#", as written in the file; nil when the key has no active line.
    static func read(_ key: String, in lines: [String]) -> String? {
        guard let i = lineIndex(of: key, in: lines), let g = groups(pattern(key), lines[i]) else { return nil }
        return g[2]
    }

    /// Replaces the hex of `key` in its existing line, keeping the spacing and anything after the value.
    /// The file's letter case is kept. Throws when the line is missing. Returns false when nothing had to change.
    @discardableResult
    static func write(_ key: String, _ hex: String) throws -> Bool {
        guard keys.contains(key) else { throw ConfigFileError.badValue(key) }
        var v = hex.trimmingCharacters(in: .whitespaces)
        if v.hasPrefix("#") { v.removeFirst() }
        guard groups(regex("^[0-9a-fA-F]{6}$"), v) != nil else { throw ConfigFileError.badValue(hex) }
        var lines = try file.readLines()
        guard let i = lineIndex(of: key, in: lines), let g = groups(pattern(key), lines[i]),
              let current = g[2] else {
            throw ConfigFileError.notFound("\(key) in current-theme.conf")
        }
        let upper = current == current.uppercased() && current != current.lowercased()
        v = upper ? v.uppercased() : v.lowercased()
        let newLine = (g[1] ?? "") + "#" + v + (g[3] ?? "")
        if newLine == lines[i] { return false }
        lines[i] = newLine
        try file.writeLines(lines)
        return true
    }
}

// MARK: - fish

/// The `fastfetch` line inside `if status is-interactive ... end` and the alias list of
/// ~/.config/fish/config.fish. Nothing else in the file is ever changed.
enum FishConf {
    static let file = ConfigFile(".config/fish/config.fish")

    /// Groups: 1 indent, 2 comment mark.
    private static let fastfetchPattern = regex("^(\\s*)(#\\s*)?fastfetch\\s*$")
    private static let blockOpeners: Set<String> = ["if", "for", "while", "function", "switch", "begin"]

    /// Index of the fastfetch line; nil if there is none or more than one inside the interactive block.
    static func fastfetchIndex(in lines: [String]) -> Int? {
        var depth = 0
        var found: [Int] = []
        for (i, line) in lines.enumerated() {
            let t = line.trimmingCharacters(in: .whitespaces)
            if depth == 0 {
                if t == "if status is-interactive" { depth = 1 }
                continue
            }
            if groups(fastfetchPattern, line) != nil {
                found.append(i)
                continue
            }
            if t.hasPrefix("#") { continue }
            let word = t.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == ";" }).first.map(String.init) ?? ""
            if blockOpeners.contains(word) { depth += 1 }
            if word == "end" { depth -= 1 }
        }
        return found.count == 1 ? found[0] : nil
    }

    /// true = runs at start, false = commented out, nil = line not found.
    static func fastfetchEnabled(in lines: [String]) -> Bool? {
        guard let i = fastfetchIndex(in: lines), let g = groups(fastfetchPattern, lines[i]) else { return nil }
        return g[2] == nil
    }

    /// Active `alias ...` lines, trimmed, for display only.
    static func aliases(in lines: [String]) -> [String] {
        lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.hasPrefix("alias ") }
    }

    /// Comments or uncomments the fastfetch line. Returns false when nothing had to change.
    @discardableResult
    static func setFastfetch(_ on: Bool) throws -> Bool {
        var lines = try file.readLines()
        guard let i = fastfetchIndex(in: lines), let g = groups(fastfetchPattern, lines[i]) else {
            throw ConfigFileError.notFound("fastfetch line in the if status is-interactive block")
        }
        let newLine = (g[1] ?? "") + (on ? "fastfetch" : "# fastfetch")
        if newLine == lines[i] { return false }
        lines[i] = newLine
        try file.writeLines(lines)
        return true
    }
}

/// One active `alias NAME='COMMAND'` line of config.fish.
struct FishAlias {
    let line: Int
    let name: String
    let command: String
}

extension FishConf {
    /// Groups: 1 indent and `alias `, 2 the name, 3 `=`, the quoted command and the rest of the line;
    /// 4 the command of a '...' value, 5 the command of a "..." value. A line starting with `#` does not match.
    private static let aliasPattern = regex(#"^(\s*alias\s+)([^\s=#'"]+)(=(?:'([^']*)'|"([^"]*)").*)$"#)
    /// Any active alias line; group 1 is the name.
    private static let anyAliasPattern = regex(#"^\s*alias\s+([^\s='"]+)"#)
    private static let aliasNamePattern = regex("^[A-Za-z0-9_-]+$")

    /// The active alias lines in the `alias NAME='COMMAND'` form, in file order.
    static func aliasEntries(in lines: [String]) -> [FishAlias] {
        lines.enumerated().compactMap { i, line in
            guard let g = groups(aliasPattern, line), let name = g[2],
                  let command = g[4] ?? g[5] else { return nil }
            return FishAlias(line: i, name: name, command: command)
        }
    }

    /// Active `alias ...` lines in any other form (trimmed); they are shown but not editable.
    static func otherAliasLines(in lines: [String]) -> [String] {
        lines.filter { groups(anyAliasPattern, $0) != nil && groups(aliasPattern, $0) == nil }
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// The trimmed name when it can be used for the alias on line `line`; otherwise throws `rejected` with the reason.
    static func checkAliasName(_ text: String, forLine line: Int, in lines: [String]) throws -> String {
        let name = text.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { throw ConfigFileError.rejected("The alias name is empty.") }
        guard name.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            throw ConfigFileError.rejected("The alias name must not contain spaces.")
        }
        guard groups(aliasNamePattern, name) != nil else {
            throw ConfigFileError.rejected("Use only letters, digits, _ and - in the alias name.")
        }
        guard !name.hasPrefix("-") else {
            throw ConfigFileError.rejected("The alias name must not start with -.")
        }
        for (i, other) in lines.enumerated() where i != line {
            if let g = groups(anyAliasPattern, other), g[1] == name {
                throw ConfigFileError.rejected("There is already an alias named \(name).")
            }
        }
        return name
    }

    /// Replaces only the name between `alias ` and `=` on line `line`; the quoted command and the rest
    /// of the line stay as they are. The file is re-read first; throws when that line no longer holds
    /// the alias `oldName`. Returns false when nothing had to change.
    @discardableResult
    static func renameAlias(line index: Int, from oldName: String, to newText: String) throws -> Bool {
        var lines = try file.readLines()
        guard lines.indices.contains(index), let g = groups(aliasPattern, lines[index]), g[2] == oldName else {
            throw ConfigFileError.rejected("config.fish was changed outside the app. Restart the app to read it again.")
        }
        let name = try checkAliasName(newText, forLine: index, in: lines)
        if name == oldName { return false }
        lines[index] = (g[1] ?? "") + name + (g[3] ?? "")
        try file.writeLines(lines)
        return true
    }
}

// MARK: - fish: adding an alias

extension FishConf {
    /// The trimmed command when it can be written as `'COMMAND'`; otherwise throws `rejected` with the reason.
    /// Not allowed: an empty command, a single quote (it would end the quoted value), a line break, and
    /// `\\` or a trailing `\`, which fish reads as escapes inside single quotes.
    static func checkAliasCommand(_ text: String) throws -> String {
        let command = text.trimmingCharacters(in: .whitespaces)
        guard !command.isEmpty else { throw ConfigFileError.rejected("The command is empty.") }
        guard !command.contains("'") else {
            throw ConfigFileError.rejected("The command must not contain a single quote (').")
        }
        guard command.rangeOfCharacter(from: .newlines) == nil else {
            throw ConfigFileError.rejected("The command must not contain line breaks.")
        }
        guard !command.contains("\\\\"), !command.hasSuffix("\\") else {
            throw ConfigFileError.rejected("The command must not contain \\\\ or end with \\: fish reads them as escapes inside '...'.")
        }
        return command
    }

    /// Where a new alias line goes and the indent it gets: right after the last active alias line,
    /// otherwise just before the `if status is-interactive` line; nil when neither is there.
    static func aliasInsertPoint(in lines: [String]) -> (index: Int, indent: String)? {
        if let last = lines.indices.last(where: { groups(anyAliasPattern, lines[$0]) != nil }) {
            return (last + 1, leadingIndent(lines[last]))
        }
        if let i = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "if status is-interactive" }) {
            return (i, leadingIndent(lines[i]))
        }
        return nil
    }

    private static func leadingIndent(_ line: String) -> String {
        String(line.prefix(while: { $0 == " " || $0 == "\t" }))
    }

    /// Inserts one line `alias NAME='COMMAND'` (see aliasInsertPoint) and returns the name as written.
    /// The file is re-read first and must still be exactly `expected` (the lines the page showed);
    /// otherwise nothing is written. The name and command are checked against the file as it is now,
    /// and the new lines are parsed back before writing. Every other line stays as it was.
    @discardableResult
    static func addAlias(name nameText: String, command commandText: String, expecting expected: [String]) throws -> String {
        var lines = try file.readLines()
        guard lines == expected else {
            throw ConfigFileError.rejected("config.fish was changed since this page read it. Nothing was written.")
        }
        let name = try checkAliasName(nameText, forLine: -1, in: lines)
        let command = try checkAliasCommand(commandText)
        guard let point = aliasInsertPoint(in: lines) else {
            throw ConfigFileError.rejected("config.fish has no alias line and no if status is-interactive line, "
                + "so there is no known place for the alias. Nothing was written.")
        }
        lines.insert(point.indent + "alias \(name)='\(command)'", at: point.index)

        // Check before writing: the new line reads back as this alias and the other aliases are unchanged.
        let before = aliasEntries(in: expected).map { $0.name + "=" + $0.command }
        let after = aliasEntries(in: lines)
        guard let entry = after.first(where: { $0.line == point.index }),
              entry.name == name, entry.command == command,
              after.filter({ $0.line != point.index }).map({ $0.name + "=" + $0.command }) == before else {
            throw ConfigFileError.badValue("the new alias line did not read back as expected. Nothing was written.")
        }
        try file.writeLines(lines)
        return name
    }
}

// MARK: - cberry

/// Settings of ~/.config/cranberry/cberryrc in the form `cberry config <key> <value>`.
/// Only the value of an existing active line is ever replaced: commented-out lines
/// (`# cberry config ...`) are not uncommented and missing keys are not appended.
enum CberryRc {
    static let file = ConfigFile(".config/cranberry/cberryrc")
    static let keys = [
        "gap", "padding", "split_ratio", "resize_step",
        "border", "border_color", "focus_follows_mouse", "mouse_modifier",
    ]

    /// Groups: 1 prefix up to the key, 2 key, 3 separator, 4 value, 5 trailing spaces and comment.
    /// A line that starts with `#` does not match.
    private static func pattern(_ key: String) -> NSRegularExpression {
        let k = NSRegularExpression.escapedPattern(for: key)
        return regex("^(\\s*cberry\\s+config\\s+)(\(k))(\\s+)([^#]*?)(\\s*(?:#.*)?)$")
    }

    private static let bindPattern = regex("^\\s*cberry\\s+bind\\s+(.*?)\\s*$")

    /// The active line that sets `key`. The file is run as a script, so the last one wins.
    static func lineIndex(of key: String, in lines: [String]) -> Int? {
        let re = pattern(key)
        var found: Int?
        for (i, line) in lines.enumerated() where groups(re, line) != nil {
            found = i
        }
        return found
    }

    /// Current value; nil when there is no active line or its value is empty.
    static func read(_ key: String, in lines: [String]) -> String? {
        guard let i = lineIndex(of: key, in: lines), let g = groups(pattern(key), lines[i]),
              let value = g[4], !value.isEmpty else { return nil }
        return value
    }

    /// Active `cberry bind ...` lines without the `cberry bind` prefix, for display only.
    static func binds(in lines: [String]) -> [String] {
        lines.compactMap { line in groups(bindPattern, line).flatMap { $0[1] } }
    }

    /// Replaces the value in the existing active line of `key`. Throws when there is no such line.
    /// Returns false when nothing had to change.
    @discardableResult
    static func write(_ key: String, _ value: String) throws -> Bool {
        guard keys.contains(key) else { throw ConfigFileError.badValue(key) }
        let v = value.trimmingCharacters(in: .whitespaces)
        // cberryrc is a shell script: allow only plain words, numbers and single spaces.
        guard !v.isEmpty, groups(regex("^[A-Za-z0-9.]+( [A-Za-z0-9.]+)*$"), v) != nil else {
            throw ConfigFileError.badValue(value)
        }
        var lines = try file.readLines()
        guard let i = lineIndex(of: key, in: lines), let g = groups(pattern(key), lines[i]) else {
            throw ConfigFileError.notFound("cberry config \(key) line")
        }
        let newLine = (g[1] ?? "") + key + (g[3] ?? " ") + v + (g[5] ?? "")
        if newLine == lines[i] { return false }
        lines[i] = newLine
        try file.writeLines(lines)
        return true
    }
}

/// One active `cberry bind 'COMBO : COMMAND'` line of cberryrc.
struct CberryBind {
    let line: Int
    let combo: String
    let command: String
}

extension CberryRc {
    /// Groups: 1 indent and `cberry bind '`, 2 the key combo, 3 the separator (` : `), 4 the command,
    /// 5 the closing quote and the rest of the line. The groups together are the whole line.
    /// cranberry splits a bind at its first ":", so the combo never contains one.
    private static let bindEntryPattern = regex(#"^(\s*cberry\s+bind\s+')([^':]*?)(\s*:\s*)([^']*)('.*)$"#)
    /// The combos this app writes: modifiers joined by ` + `, then ` - ` and the key.
    private static let comboPattern = regex(
        #"^(alt|cmd|ctrl|shift|fn|meh|hyper)( \+ (alt|cmd|ctrl|shift|fn|meh|hyper))* - ([a-z0-9]|return|left|right|up|down)$"#)

    /// The active single-quoted bind lines, in file order.
    static func bindEntries(in lines: [String]) -> [CberryBind] {
        lines.enumerated().compactMap { i, line in
            guard let g = groups(bindEntryPattern, line), let combo = g[2], let command = g[4] else { return nil }
            return CberryBind(line: i, combo: combo, command: command.trimmingCharacters(in: .whitespaces))
        }
    }

    /// Active `cberry bind ...` lines in any other form (without the `cberry bind` prefix); shown, not editable.
    static func otherBinds(in lines: [String]) -> [String] {
        lines.compactMap { line in
            guard groups(bindEntryPattern, line) == nil else { return nil }
            return groups(bindPattern, line).flatMap { $0[1] }
        }
    }

    /// What a combo means, for finding duplicates: the set of modifiers (meh and hyper expanded,
    /// other spellings cranberry accepts mapped to one name) and the key.
    static func comboIdentity(_ combo: String) -> String {
        let t = combo.lowercased().trimmingCharacters(in: .whitespaces)
        var modsText = ""
        var keyText = t
        if let r = t.range(of: "-", options: .backwards) {
            let after = t[r.upperBound...].trimmingCharacters(in: .whitespaces)
            if !after.isEmpty {
                modsText = String(t[..<r.lowerBound])
                keyText = after
            }
        }
        let modNames = ["opt": "alt", "option": "alt", "command": "cmd", "control": "ctrl"]
        var mods = Set<String>()
        for part in modsText.split(separator: "+") {
            let name = part.trimmingCharacters(in: .whitespaces)
            if name.isEmpty { continue }
            switch modNames[name] ?? name {
            case "meh": mods.formUnion(["alt", "shift", "ctrl"])
            case "hyper": mods.formUnion(["cmd", "alt", "shift", "ctrl"])
            case let other: mods.insert(other)
            }
        }
        let keyNames = ["enter": "return", "esc": "escape"]
        return mods.sorted().joined(separator: "+") + " - " + (keyNames[keyText] ?? keyText)
    }

    /// The combo in the form this app writes (lower case, single spaces around "+" and "-"), when it is
    /// valid for the bind on line `line`: not empty, in the notation above, no modifier twice, and not
    /// the combo of another bind in `binds`. Otherwise throws `rejected` with the reason.
    static func checkCombo(_ text: String, forLine line: Int, in binds: [CberryBind]) throws -> String {
        var t = text.lowercased().trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { throw ConfigFileError.rejected("The key combo is empty.") }
        t = regex(#"\s*\+\s*"#).stringByReplacingMatches(
            in: t, range: NSRange(location: 0, length: (t as NSString).length), withTemplate: " + ")
        t = regex(#"\s*-\s*"#).stringByReplacingMatches(
            in: t, range: NSRange(location: 0, length: (t as NSString).length), withTemplate: " - ")
        guard groups(comboPattern, t) != nil else {
            throw ConfigFileError.rejected("\"\(text)\" is not a cranberry key combo. Write modifiers, \" - \" and a key, "
                + "like shift + alt - h. Modifiers: alt, cmd, ctrl, shift, fn, meh, hyper. "
                + "Keys: a-z, 0-9, return, left, right, up, down.")
        }
        let modsText = t.components(separatedBy: " - ").first ?? ""
        var expanded: [String] = []
        for name in modsText.components(separatedBy: " + ") {
            switch name {
            case "meh": expanded += ["alt", "shift", "ctrl"]
            case "hyper": expanded += ["cmd", "alt", "shift", "ctrl"]
            default: expanded.append(name)
            }
        }
        guard Set(expanded).count == expanded.count else {
            throw ConfigFileError.rejected("A modifier is listed twice in \(t) (meh = alt + shift + ctrl, "
                + "hyper = cmd + alt + shift + ctrl).")
        }
        let identity = comboIdentity(t)
        if let other = binds.first(where: { $0.line != line && comboIdentity($0.combo) == identity }) {
            throw ConfigFileError.rejected("\(t) is already used by another bind: \(other.command)")
        }
        return t
    }

    /// Replaces only the combo between `cberry bind '` and ` : ` on line `line`; the command, the rest of
    /// the line and every other line stay as they are. The file is re-read first and the combo is checked
    /// against it; throws when that line no longer holds `oldCombo`. Returns false when nothing had to change.
    @discardableResult
    static func setBindCombo(line index: Int, from oldCombo: String, to newText: String) throws -> Bool {
        var lines = try file.readLines()
        guard lines.indices.contains(index), let g = groups(bindEntryPattern, lines[index]), g[2] == oldCombo else {
            throw ConfigFileError.rejected("cberryrc was changed outside the app. Restart the app to read it again.")
        }
        let combo = try checkCombo(newText, forLine: index, in: bindEntries(in: lines))
        if combo == oldCombo { return false }
        lines[index] = (g[1] ?? "") + combo + (g[3] ?? " : ") + (g[4] ?? "") + (g[5] ?? "'")
        try file.writeLines(lines)
        return true
    }
}

// MARK: - fastfetch

/// The `"modules": [ ... ]` array of ~/.config/fastfetch/config.jsonc (a JSON array of module name strings).
/// Only the text between its brackets is ever replaced; comments, "$schema", "logo", "display"
/// and everything else in the file stay exactly as they were.
enum FastfetchConf {
    static let file = ConfigFile(".config/fastfetch/config.jsonc")

    /// Every module name of fastfetch's doc/json_schema.json, in the order enabled modules are written.
    /// The modules the user already had (title ... colors) keep their relative order.
    static let modules: [(name: String, label: String)] = [
        ("title", "Title (user@host)"),
        ("separator", "Separator line"),
        ("os", "OS"),
        ("host", "Host (Mac model)"),
        ("bios", "BIOS / firmware"),
        ("board", "Motherboard"),
        ("chassis", "Chassis"),
        ("kernel", "Kernel"),
        ("initsystem", "Init system"),
        ("uptime", "Uptime"),
        ("loadavg", "Load average"),
        ("processes", "Process count"),
        ("packages", "Packages"),
        ("shell", "Shell"),
        ("editor", "Editor"),
        ("display", "Display"),
        ("monitor", "Monitor"),
        ("brightness", "Brightness"),
        ("de", "Desktop environment"),
        ("wm", "Window manager"),
        ("wmtheme", "WM theme"),
        ("theme", "Theme"),
        ("icons", "Icons"),
        ("font", "Font"),
        ("cursor", "Cursor"),
        ("wallpaper", "Wallpaper"),
        ("terminal", "Terminal"),
        ("terminalfont", "Terminal font"),
        ("terminalsize", "Terminal size"),
        ("terminaltheme", "Terminal theme"),
        ("cpu", "CPU"),
        ("cpucache", "CPU cache"),
        ("cpuusage", "CPU usage"),
        ("gpu", "GPU"),
        ("opencl", "OpenCL"),
        ("opengl", "OpenGL"),
        ("vulkan", "Vulkan"),
        ("memory", "Memory"),
        ("physicalmemory", "Physical memory"),
        ("swap", "Swap"),
        ("disk", "Disk"),
        ("physicaldisk", "Physical disk"),
        ("diskio", "Disk I/O"),
        ("btrfs", "Btrfs"),
        ("zpool", "ZFS pool"),
        ("battery", "Battery"),
        ("poweradapter", "Power adapter"),
        ("netio", "Network I/O"),
        ("localip", "Local IP"),
        ("publicip", "Public IP (network request)"),
        ("dns", "DNS"),
        ("wifi", "Wi-Fi"),
        ("bluetooth", "Bluetooth"),
        ("bluetoothradio", "Bluetooth radio"),
        ("sound", "Sound"),
        ("camera", "Camera"),
        ("gamepad", "Gamepad"),
        ("keyboard", "Keyboard"),
        ("mouse", "Mouse"),
        ("users", "Users"),
        ("lm", "Login manager"),
        ("locale", "Locale"),
        ("bootmgr", "Boot manager"),
        ("tpm", "TPM"),
        ("codec", "Codecs"),
        ("top", "Top processes"),
        ("weather", "Weather (network request)"),
        ("version", "fastfetch version"),
        ("command", "Command (needs extra config)"),
        ("custom", "Custom text (needs extra config)"),
        ("logo", "Logo as a module"),
        ("datetime", "Date and time"),
        ("media", "Now playing"),
        ("player", "Music player"),
        ("break", "Empty line"),
        ("colors", "Color blocks"),
    ]
    static let names: [String] = modules.map { $0.name }

    /// Groups: 1 the line start up to and including "[", 2 the array content, 3 "]".
    /// The key must start its line, so a commented-out `// "modules": [` never matches.
    private static let blockPattern = regex(
        #"^([ \t]*"modules"[ \t]*:[ \t]*\[)(.*?)(\])"#, [.dotMatchesLineSeparators, .anchorsMatchLines])
    /// The whole array content: only plain strings, commas (a trailing one too) and whitespace.
    /// Comments, objects or escapes inside the array make it unsupported, so nothing is ever lost on rewrite.
    private static let contentPattern = regex(#"^\s*(?:"[^"\\\r\n]*"\s*,\s*)*(?:"[^"\\\r\n]*"\s*)?$"#)
    private static let entryPattern = regex(#""([^"\\\r\n]*)""#)
    private static let firstEntryIndentPattern = regex(#"\n([ \t]*)""#)

    /// The parsed array: `known` are names from `modules` (compared in lower case, as fastfetch does),
    /// `unknown` are any other strings, in file order and spelled as in the file.
    struct Block {
        let contentRange: NSRange
        let known: Set<String>
        let unknown: [String]
        let entryIndent: String
        let closingIndent: String
        let newline: String
    }

    /// Throws when there is no modules block, more than one, or its content is not a plain list of
    /// distinct strings. In that case the file must not be written.
    static func parse(_ text: String) throws -> Block {
        let ns = text as NSString
        let matches = blockPattern.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard let m = matches.first else {
            throw ConfigFileError.notFound("\"modules\": [ ... ] block in config.jsonc")
        }
        guard matches.count == 1 else {
            throw ConfigFileError.badValue("config.jsonc has more than one \"modules\" block")
        }
        let opening = ns.substring(with: m.range(at: 1))
        let content = ns.substring(with: m.range(at: 2))
        guard groups(contentPattern, content) != nil else {
            throw ConfigFileError.badValue("the modules array has comments, objects or other non-string entries")
        }
        let c = content as NSString
        let entries = entryPattern.matches(in: content, range: NSRange(location: 0, length: c.length))
            .map { c.substring(with: $0.range(at: 1)) }
        let lowered = entries.map { $0.lowercased() }
        guard Set(lowered).count == lowered.count else {
            throw ConfigFileError.badValue("a module is listed more than once in the modules array")
        }
        let known = Set(lowered.filter { names.contains($0) })
        let unknown = entries.filter { !names.contains($0.lowercased()) }

        let keyIndent = String(opening.prefix(while: { $0 == " " || $0 == "\t" }))
        let entryIndent = groups(firstEntryIndentPattern, content).flatMap { $0[1] } ?? keyIndent + "  "
        var closingIndent = keyIndent
        if let lastBreak = content.range(of: "\n", options: .backwards) {
            let tail = String(content[lastBreak.upperBound...])
            if tail.allSatisfy({ $0 == " " || $0 == "\t" }) { closingIndent = tail }
        }
        let newline = content.contains("\r\n") ? "\r\n" : "\n"
        return Block(contentRange: m.range(at: 2), known: known, unknown: unknown,
                     entryIndent: entryIndent, closingIndent: closingIndent, newline: newline)
    }

    /// New array content: enabled names in `names` order, then the unknown strings, one per line,
    /// a comma after every entry but the last. An empty list gives `[]`.
    static func render(_ known: Set<String>, _ unknown: [String], like block: Block) -> String {
        let entries = names.filter { known.contains($0) } + unknown
        if entries.isEmpty { return "" }
        let lines = entries.map { block.entryIndent + "\"" + $0 + "\"" }
        return block.newline + lines.joined(separator: "," + block.newline) + block.newline + block.closingIndent
    }

    /// Adds or removes one module in the file's modules array. Returns false when nothing had to change.
    /// The file is re-read first, so edits made outside the app are kept.
    @discardableResult
    static func setModule(_ name: String, _ on: Bool) throws -> Bool {
        guard names.contains(name) else { throw ConfigFileError.badValue(name) }
        let text = try file.readLines().joined(separator: "\n")
        let block = try parse(text)
        var known = block.known
        if on { known.insert(name) } else { known.remove(name) }
        if known == block.known { return false }
        let newText = (text as NSString).replacingCharacters(
            in: block.contentRange, with: render(known, block.unknown, like: block))
        // Check the result before writing: same modules as intended, nothing else touched.
        let check = try parse(newText)
        guard check.known == known, check.unknown == block.unknown else {
            throw ConfigFileError.badValue("the rewritten modules array did not read back as expected")
        }
        try file.writeLines(newText.components(separatedBy: "\n"))
        return true
    }
}

// MARK: - rice-settings' own config

extension ConfigFile {
    /// Writes the lines without a backup, creating the folder when needed. Only for the app's own files.
    func writeLinesWithoutBackup(_ lines: [String]) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}

/// ~/.config/rice-settings/config.toml, the app's own settings: `accent = "#rrggbb"`.
enum AppConf {
    static let file = ConfigFile(".config/rice-settings/config.toml")

    /// Groups: 1 `accent =` with spacing, 2 the value between the quotes, 3 the rest of the line.
    private static let accentPattern = regex(#"^(\s*accent\s*=\s*)"([^"]*)"(.*)$"#)
    private static let hexPattern = regex("^#[0-9a-fA-F]{6}$")

    /// The accent as written ("#rrggbb"); nil when the file, the key or a valid value is missing.
    static func readAccent() -> String? {
        guard let lines = try? file.readLines() else { return nil }
        for line in lines.reversed() {
            if let g = groups(accentPattern, line), let value = g[2], groups(hexPattern, value) != nil {
                return value
            }
        }
        return nil
    }

    /// Sets `accent = "#rrggbb"`: replaces the last accent line or appends one; creates the file and
    /// its folder when missing. No backup (the file belongs to this app). Returns false when nothing changed.
    @discardableResult
    static func writeAccent(_ hex: String) throws -> Bool {
        guard groups(hexPattern, hex) != nil else { throw ConfigFileError.badValue(hex) }
        var lines: [String] = []
        if FileManager.default.fileExists(atPath: file.url.path) {
            lines = try file.readLines()
        }
        let newLine = "accent = \"\(hex)\""
        if let i = lines.lastIndex(where: { groups(accentPattern, $0) != nil }) {
            if lines[i] == newLine { return false }
            lines[i] = newLine
        } else if lines.isEmpty || lines == [""] {
            lines = [newLine, ""]
        } else if let last = lines.last, last.isEmpty {
            lines.insert(newLine, at: lines.count - 1)
        } else {
            lines.append(newLine)
            lines.append("")
        }
        try file.writeLinesWithoutBackup(lines)
        return true
    }
}

// MARK: - cberry: the rule for this app's window, and cberry reload

extension CberryRc {
    /// cberry matches a rule against the window owner name (kCGWindowOwnerName), which for this
    /// SwiftPM executable is its process name.
    static let windowRuleApp = "rice-settings"
    /// The centre quarter of the screen.
    static let windowRuleGrid = "4:4:1:1:2:2"
    /// Written in the quoting style of the existing `cberry rule float "wallpicker"` line.
    static let windowRuleLine = "cberry rule grid \(windowRuleGrid) \"\(windowRuleApp)\""

    /// Groups: 1 indent, 2 grid spec, 3 app name as written (quotes kept), 4 trailing comment.
    /// A line starting with `#` does not match.
    private static let gridRulePattern = regex(#"^(\s*)cberry\s+rule\s+grid\s+(\S+)\s+([^#]*?)\s*(#.*)?$"#)
    /// Any active `cberry rule ...` line.
    private static let anyRulePattern = regex(#"^\s*cberry\s+rule\s"#)

    /// The name without one pair of surrounding double or single quotes, as the shell passes it on.
    private static func unquoted(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespaces)
        for q in ["\"", "'"] where t.count >= 2 && t.hasPrefix(q) && t.hasSuffix(q) {
            return String(t.dropFirst().dropLast())
        }
        return t
    }

    /// Indices of the active `cberry rule grid <spec> <app>` lines whose app is this app, in any grid and quoting.
    static func windowRuleIndices(in lines: [String]) -> [Int] {
        lines.indices.filter { i in
            guard let g = groups(gridRulePattern, lines[i]), let app = g[3] else { return false }
            return unquoted(app) == windowRuleApp
        }
    }

    /// The grid spec of this app's rule line; nil when there is none.
    static func windowRuleGridSpec(in lines: [String]) -> String? {
        windowRuleIndices(in: lines).last.flatMap { groups(gridRulePattern, lines[$0]).flatMap { $0[2] } }
    }

    /// On: the first rule grid line of this app becomes `windowRuleLine` (indent and trailing comment kept,
    /// further lines for this app removed); without one, `windowRuleLine` is inserted after the last active
    /// `cberry rule` line, or at the end of the file when there is none. Off: every rule grid line of this
    /// app is removed and nothing else. Writes through writeLines (the first-write backup is never
    /// overwritten). Returns false when nothing had to change.
    @discardableResult
    static func setWindowRule(_ on: Bool) throws -> Bool {
        var lines = try file.readLines()
        let found = windowRuleIndices(in: lines)
        if on {
            if let first = found.first {
                let g = groups(gridRulePattern, lines[first])
                let indent = g.flatMap { $0[1] } ?? ""
                let comment = g.flatMap { $0[4] }.map { "  " + $0 } ?? ""
                let newLine = indent + windowRuleLine + comment
                var changed = false
                if lines[first] != newLine {
                    lines[first] = newLine
                    changed = true
                }
                for i in found.dropFirst().reversed() {
                    lines.remove(at: i)
                    changed = true
                }
                if !changed { return false }
            } else if let last = lines.indices.last(where: { groups(anyRulePattern, lines[$0]) != nil }) {
                let indent = String(lines[last].prefix(while: { $0 == " " || $0 == "\t" }))
                lines.insert(indent + windowRuleLine, at: last + 1)
            } else if let last = lines.last, last.isEmpty {
                lines.insert(windowRuleLine, at: lines.count - 1)
            } else {
                lines.append(windowRuleLine)
                lines.append("")
            }
        } else {
            if found.isEmpty { return false }
            for i in found.reversed() { lines.remove(at: i) }
        }
        try file.writeLines(lines)
        return true
    }

    enum ReloadResult {
        case done
        case failed(code: Int32, output: String)
        case notStarted(String)
    }

    /// Runs `cberry reload` off the main thread: ~/bin/cberry if it is there, otherwise through /usr/bin/env.
    /// `completion` is called on the main thread.
    static func reload(completion: @escaping (ReloadResult) -> Void) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let local = home.appendingPathComponent("bin/cberry").path
        let process = Process()
        if FileManager.default.isExecutableFile(atPath: local) {
            process.executableURL = URL(fileURLWithPath: local)
            process.arguments = ["reload"]
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["cberry", "reload"]
        }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        DispatchQueue.global(qos: .userInitiated).async {
            let result: ReloadResult
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let output = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                result = process.terminationStatus == 0
                    ? .done
                    : .failed(code: process.terminationStatus, output: output)
            } catch {
                result = .notStarted(error.localizedDescription)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }
}
