import Foundation

struct SysvizConfig: Equatable {
    var bars = 64
    var barGap = 1
    var framerate = 30
    var colorMode = "solid"
    var color = "#ffffff"
    var colorLow = "#ffffff"
    var colorHigh = "#ffffff"

    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/sysviz/config.toml")

    static func load() -> SysvizConfig {
        var c = SysvizConfig()
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return c }
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            let rest = parts[1]
            let value: String
            if rest.hasPrefix("\"") {
                value = String(rest.dropFirst().prefix { $0 != "\"" })
            } else {
                value = String(rest.prefix { $0 != "#" }).trimmingCharacters(in: .whitespaces)
            }
            switch parts[0] {
            case "bars": c.bars = Int(value) ?? c.bars
            case "bar_gap": c.barGap = Int(value) ?? c.barGap
            case "framerate": c.framerate = Int(value) ?? c.framerate
            case "color_mode": c.colorMode = value
            case "color": c.color = value
            case "color_low": c.colorLow = value
            case "color_high": c.colorHigh = value
            default: break
            }
        }
        return c
    }

    func save() throws {
        let text = """
        bars = \(bars)
        bar_gap = \(barGap)
        framerate = \(framerate)

        color_mode = "\(colorMode)"
        color = "\(color)"
        color_low = "\(colorLow)"
        color_high = "\(colorHigh)"

        """
        try FileManager.default.createDirectory(
            at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: Self.url, atomically: true, encoding: .utf8)
    }
}
