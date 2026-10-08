import Foundation

/// A pixel size, width × height.
public struct PixelSize: Codable, Equatable, Hashable, Sendable, CustomStringConvertible {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    /// "2048×1280", as the Submit Review list shows sizes.
    public var description: String { "\(width)×\(height)" }
}

/// The default AI tool of a Hot Sheet project, from `hotsheet-cli ai-settings get --json`
/// (docs/03 §3.6): the tool (provider) id such as `claude` or `codex`, and its model, such as
/// `opus` or `gpt-6.1-sol`.
public struct AIToolSettings: Codable, Equatable, Sendable {
    public var tool: String
    public var model: String?

    public init(tool: String, model: String? = nil) {
        self.tool = tool
        self.model = model
    }

    /// Parses the CLI's JSON (`{"tool":"claude","model":"sonnet","effort":"medium"}`; `provider`
    /// is accepted for `tool`). Nil when it has no tool.
    public static func parse(_ json: String) -> AIToolSettings? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tool = (object["tool"] ?? object["provider"]) as? String,
              !tool.trimmingCharacters(in: .whitespaces).isEmpty
        else { return nil }
        let model = (object["model"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return AIToolSettings(tool: tool.trimmingCharacters(in: .whitespaces), model: model)
    }
}

/// The size filed attachments are scaled down to so the target project's AI tool gets media it
/// can use (`HS2-PT8PM6`). Images and video frames keep their aspect ratio and are never scaled
/// up. Spec: docs/07-review-session.md §7.5.1.
public struct MediaScaleTarget: Codable, Equatable, Hashable, Sendable {
    public enum Rule: Codable, Equatable, Hashable, Sendable {
        /// Claude's own resize rule: the largest aspect-preserving size whose sides, padded to a
        /// multiple of 28, are at most `maxEdge`, and whose visual tokens
        /// ⌈w/28⌉ × ⌈h/28⌉ are at most `maxTokens`.
        case claude(maxEdge: Int, maxTokens: Int)
        /// OpenAI's patch rule for `high` detail (`HS2-Q0R78W`): fits within `maxEdge` × `maxEdge`,
        /// then shrinks until the 32 × 32 patches ⌈w/32⌉ × ⌈h/32⌉ are at most `maxPatches`.
        case patches(maxEdge: Int, maxPatches: Int)
        /// Fits within `maxEdge` × `maxEdge` (the longest side at most `maxEdge`).
        case longestEdge(Int)
    }

    public var rule: Rule
    /// Who the size is for, as the Submit Review list says it: "Claude", "Codex", or "AI".
    public var audience: String

    public init(rule: Rule, audience: String) {
        self.rule = rule
        self.audience = audience
    }

    /// Claude's standard resolution tier (Claude models before 4.7).
    public static let claudeStandard = MediaScaleTarget(rule: .claude(maxEdge: 1568, maxTokens: 1568), audience: "Claude")
    /// Claude's high-resolution tier (Claude 4.7 and later models).
    public static let claudeHighResolution = MediaScaleTarget(rule: .claude(maxEdge: 2576, maxTokens: 4784), audience: "Claude")
    /// Codex / GPT at high detail, Codex's default for attached images: fits within 2048 × 2048
    /// and 2,500 patches of 32 × 32 px (2048×2048 → 1600×1600), the same for every GPT model Hot
    /// Sheet offers for codex.
    public static let codex = MediaScaleTarget(rule: .patches(maxEdge: 2048, maxPatches: 2500), audience: "Codex")
    /// Any other tool, or when the tool can't be determined: 2048 px on the longest side.
    public static let fallback = MediaScaleTarget(rule: .longestEdge(2048), audience: "AI")

    /// The target for a project's default AI tool; `fallback` when it is unknown. A model that is
    /// recognisably a Claude model picks Claude's rule whatever the tool, such as antigravity's
    /// `claude-opus-4-6-thinking` or opencode's `anthropic/claude-sonnet-4-5` (`HS2-8G9F3R`).
    public static func forTool(_ settings: AIToolSettings?) -> MediaScaleTarget {
        guard let settings else { return .fallback }
        let tool = settings.tool.lowercased()
        if tool == "claude" || ClaudeVisionTier.isClaudeModel(settings.model) {
            return ClaudeVisionTier.of(model: settings.model) == .highResolution ? .claudeHighResolution : .claudeStandard
        }
        return tool == "codex" ? .codex : .fallback
    }

    /// Asks the project's Hot Sheet (`HotSheetClient.aiSettings`) for its default AI tool.
    /// Any failure (an old CLI without `ai-settings`, unreadable output) gives `fallback`.
    public static func detect(using client: HotSheetClient) -> MediaScaleTarget {
        forTool((try? client.aiSettings()) ?? nil)
    }

    /// The size an image of `size` is filed at: `size` itself when it already fits.
    public func imageSize(for size: PixelSize) -> PixelSize {
        guard size.width > 0, size.height > 0 else { return size }
        switch rule {
        case let .claude(maxEdge, maxTokens):
            return Self.claudeResized(size, maxEdge: maxEdge, maxTokens: maxTokens)
        case let .patches(maxEdge, maxPatches):
            return Self.patchResized(size, maxEdge: maxEdge, maxPatches: maxPatches)
        case let .longestEdge(limit):
            let long = max(size.width, size.height)
            guard long > limit else { return size }
            let scale = Double(limit) / Double(long)
            if size.width >= size.height {
                return PixelSize(width: limit, height: max(Int((Double(size.height) * scale).rounded(.toNearestOrEven)), 1))
            }
            return PixelSize(width: max(Int((Double(size.width) * scale).rounded(.toNearestOrEven)), 1), height: limit)
        }
    }

    /// The size a video of `size` is filed at: each frame sized like an image (the same edge
    /// and, for Claude, per-frame token limits), then rounded down to even sides for H.264.
    /// `size` itself when it already fits (the movie is then not re-encoded for size).
    public func videoSize(for size: PixelSize) -> PixelSize {
        let scaled = imageSize(for: size)
        guard scaled != size else { return size }
        return PixelSize(width: max(scaled.width & ~1, 2), height: max(scaled.height & ~1, 2))
    }

    /// The filed size of a capture of `kind`.
    public func size(for size: PixelSize, kind: MediaKind) -> PixelSize {
        kind == .video ? videoSize(for: size) : imageSize(for: size)
    }

    /// Visual tokens Claude spends on an image: one per 28 × 28 patch.
    public static func claudeTokens(_ size: PixelSize) -> Int {
        ((size.width + 27) / 28) * ((size.height + 27) / 28)
    }

    /// Patches an OpenAI model spends on an image: one per 32 × 32 patch.
    public static func openAIPatches(_ size: PixelSize) -> Int {
        ((size.width + 31) / 32) * ((size.height + 31) / 32)
    }

    /// OpenAI's patch resize (developers.openai.com, "Images and vision", patch-based sizing), as
    /// Codex implements it (`prompt_image_output_dimensions_for_limits` in `codex-utils-image`):
    /// fit the edge limit with sides rounded to nearest, then scale by
    /// √(32² × maxPatches / (w × h)), reduced so the patch grid is whole, flooring the sides.
    static func patchResized(_ size: PixelSize, maxEdge: Int, maxPatches: Int) -> PixelSize {
        func fits(_ size: PixelSize) -> Bool {
            size.width <= maxEdge && size.height <= maxEdge && openAIPatches(size) <= maxPatches
        }
        if fits(size) { return size }
        let edgeScale = min(Double(maxEdge) / Double(max(size.width, size.height)), 1)
        let edged = PixelSize(
            width: max(Int((Double(size.width) * edgeScale).rounded()), 1),
            height: max(Int((Double(size.height) * edgeScale).rounded()), 1)
        )
        if fits(edged) { return edged }
        let width = Double(edged.width), height = Double(edged.height)
        var scale = (32 * 32 * Double(maxPatches) / width / height).squareRoot()
        let wide = width * scale / 32, high = height * scale / 32
        scale *= min(wide.rounded(.down) / wide, high.rounded(.down) / high)
        return PixelSize(
            width: max(Int((width * scale).rounded(.down)), 1),
            height: max(Int((height * scale).rounded(.down)), 1)
        )
    }

    /// Claude's reference resize (platform.claude.com, "How Claude resizes and pads images"):
    /// a binary search along the long edge for the largest aspect-preserving size that fits both
    /// limits, the short edge rounded half to even.
    static func claudeResized(_ size: PixelSize, maxEdge: Int, maxTokens: Int) -> PixelSize {
        func fits(_ width: Int, _ height: Int) -> Bool {
            (width + 27) / 28 * 28 <= maxEdge && (height + 27) / 28 * 28 <= maxEdge
                && claudeTokens(PixelSize(width: width, height: height)) <= maxTokens
        }
        if fits(size.width, size.height) { return size }
        if size.height > size.width {
            let turned = claudeResized(PixelSize(width: size.height, height: size.width), maxEdge: maxEdge, maxTokens: maxTokens)
            return PixelSize(width: turned.height, height: turned.width)
        }
        let aspect = Double(size.width) / Double(size.height)
        func short(_ long: Int) -> Int { max(Int((Double(long) / aspect).rounded(.toNearestOrEven)), 1) }
        var low = 1, high = size.width // low always fits; high never does
        while low + 1 < high {
            let mid = (low + high) / 2
            if fits(mid, short(mid)) { low = mid } else { high = mid }
        }
        return PixelSize(width: low, height: short(low))
    }
}

public extension MediaScaleTarget {
    /// `bundle` with each capture's pixel size as filed at this target, plus the captures that
    /// shrink (media id → their size before scaling). Annotation coordinates are normalized to
    /// the media (docs/02 §2.3), so they stay as they are and still match the scaled files.
    func apply(to bundle: ReviewBundle) -> (bundle: ReviewBundle, scaledFrom: [String: PixelSize]) {
        var bundle = bundle
        var scaledFrom: [String: PixelSize] = [:]
        for index in bundle.media.indices {
            let item = bundle.media[index]
            let original = PixelSize(width: item.pixelWidth, height: item.pixelHeight)
            let filed = size(for: original, kind: item.kind)
            guard filed != original else { continue }
            scaledFrom[item.id] = original
            bundle.media[index].pixelWidth = filed.width
            bundle.media[index].pixelHeight = filed.height
        }
        return (bundle, scaledFrom)
    }
}

/// Claude's image resolution tiers. Per the Vision docs (platform.claude.com/docs/en/build-with-claude/vision,
/// "Resolution and token cost"): Claude 4.7 and later models get the high-resolution tier
/// (2576 px, 4784 visual tokens); all other models the standard tier (1568 px, 1568 tokens).
public enum ClaudeVisionTier: Equatable, Sendable {
    case standard
    case highResolution

    /// The tier of a Hot Sheet Claude model: an alias (`opus`, `sonnet`, `fable`, `mythos` name
    /// current 4.7+ models; `haiku` is Haiku 4.5) or a full id (`claude-opus-4-6`,
    /// `claude-sonnet-5-5`, `claude-3-5-sonnet-20241022`, `us.anthropic.claude-opus-4-7`).
    /// Unknown models get the standard tier, the smaller size every model reads well.
    public static func of(model: String?) -> ClaudeVisionTier {
        guard var name = model?.lowercased().trimmingCharacters(in: .whitespaces), !name.isEmpty else { return .standard }
        if let bracket = name.firstIndex(of: "[") { name = String(name[..<bracket]) } // `opus[1m]`
        let families = ["opus", "sonnet", "haiku", "fable", "mythos"]
        if let alias = families.first(where: { name == $0 || name.hasPrefix($0) && !name.contains("-") }) {
            return alias == "haiku" ? .standard : .highResolution // `opusplan` is Opus too
        }
        guard let range = name.range(of: "claude-") else { return .standard }
        // `-`, and `.` / `@` as in OpenRouter's `claude-opus-4.7` and Vertex's `claude-opus-4-7@2025…`.
        let parts = name[range.upperBound...].split(whereSeparator: { "-.@".contains($0) }).map(String.init)
        guard let familyIndex = parts.firstIndex(where: { families.contains($0) }) else { return .standard }
        if parts[familyIndex] == "fable" || parts[familyIndex] == "mythos" { return .highResolution }
        // `claude-opus-4-7` puts the version after the family; `claude-3-5-sonnet` before it.
        let after = Array(parts[(familyIndex + 1)...])
        let before = Array(parts[..<familyIndex])
        guard let version = Self.version(after) ?? Self.version(before) else { return .standard }
        return version.major > 4 || version.major == 4 && version.minor >= 7 ? .highResolution : .standard
    }

    /// Whether `model` is recognisably a Claude model id, whichever tool runs it: an id starting
    /// `claude-` (`claude-sonnet-4-6`, antigravity's `claude-opus-4-6-thinking`), after a provider
    /// path (`anthropic/claude-…`, `openrouter/anthropic/claude-…`) or a Bedrock-style prefix
    /// (`us.anthropic.claude-…`), and naming a Claude family. Bare aliases such as `opus` count
    /// only under the `claude` tool, so they are not recognised here; nor is anything else.
    public static func isClaudeModel(_ model: String?) -> Bool {
        guard var name = model?.lowercased().trimmingCharacters(in: .whitespaces), !name.isEmpty else { return false }
        if let bracket = name.firstIndex(of: "[") { name = String(name[..<bracket]) }
        if let slash = name.lastIndex(of: "/") { name = String(name[name.index(after: slash)...]) }
        guard name.hasPrefix("claude-") || name.contains("anthropic.claude-"),
              let range = name.range(of: "claude-")
        else { return false }
        let families: Set<String> = ["opus", "sonnet", "haiku", "fable", "mythos"]
        return name[range.upperBound...].split(whereSeparator: { "-.@".contains($0) }).contains { families.contains(String($0)) }
    }

    /// `["4", "7"]` → 4.7; a date suffix (`20250929`) is not a minor version.
    private static func version(_ parts: [String]) -> (major: Int, minor: Int)? {
        guard let first = parts.first, let major = Int(first), major < 100 else { return nil }
        let minor = parts.dropFirst().first.flatMap { Int($0) }.flatMap { $0 < 100 ? $0 : nil } ?? 0
        return (major, minor)
    }
}
