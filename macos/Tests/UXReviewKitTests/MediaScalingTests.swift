import Foundation
import Testing
@testable import UXReviewKit

/// AI downscaling when filing (HS2-PT8PM6, docs/07 §7.5.1): the size rules per AI tool, the
/// Claude model → tier mapping, detection through `hotsheet-cli ai-settings`, and its fallbacks.
struct MediaScalingTests {
    static func size(_ width: Int, _ height: Int) -> PixelSize { PixelSize(width: width, height: height) }

    // MARK: Claude's resize rule

    /// The Vision docs' own examples (platform.claude.com, "Resolution and token cost" and
    /// "How Claude resizes and pads images").
    @Test(arguments: [
        (size(200, 200), size(200, 200)),
        (size(1000, 1000), size(1000, 1000)),
        (size(1092, 1092), size(1092, 1092)),
        (size(1920, 1080), size(1456, 819)),
        // The docs' table says 1269×952; their reference implementation (which this follows,
        // and which the docs say to use) gives 1270×952, also 1564 tokens.
        (size(2000, 1500), size(1270, 952)),
        (size(3840, 2160), size(1456, 819)),
        // Portrait A4 at 130 DPI: both sides fit the edge, the token budget does not.
        (size(1075, 1520), size(924, 1307)),
    ])
    func claudeStandardTierMatchesTheDocs(original: PixelSize, filed: PixelSize) {
        #expect(MediaScaleTarget.claudeStandard.imageSize(for: original) == filed)
    }

    @Test(arguments: [
        (size(200, 200), size(200, 200)),
        (size(1920, 1080), size(1920, 1080)),
        (size(2000, 1500), size(2000, 1500)),
        (size(3840, 2160), size(2576, 1449)),
        (size(1075, 1520), size(1075, 1520)), // 2145 tokens fit the 4784 budget
    ])
    func claudeHighResolutionTierMatchesTheDocs(original: PixelSize, filed: PixelSize) {
        #expect(MediaScaleTarget.claudeHighResolution.imageSize(for: original) == filed)
    }

    /// Every result fits both limits, keeps the aspect ratio within rounding, never grows, and is
    /// the largest such size (one more pixel on the long edge no longer fits).
    @Test func claudeSizesFitBothLimitsAndAreTheLargestThatDo() {
        for target in [MediaScaleTarget.claudeStandard, .claudeHighResolution] {
            guard case let .claude(maxEdge, maxTokens) = target.rule else { Issue.record("not a Claude rule"); continue }
            for (width, height) in [
                (5120, 2880),
                (2880, 5120),
                (1170, 2532),
                (6000, 400),
                (400, 6000),
                (3000, 3000),
                (1569, 1569),
                (2577, 10),
            ] {
                let filed = target.imageSize(for: Self.size(width, height))
                #expect(filed.width <= width && filed.height <= height)
                #expect((filed.width + 27) / 28 * 28 <= maxEdge && (filed.height + 27) / 28 * 28 <= maxEdge)
                #expect(MediaScaleTarget.claudeTokens(filed) <= maxTokens)
                let ratio = Double(width) / Double(height)
                let long = max(filed.width, filed.height), short = min(filed.width, filed.height)
                let expectedShort = Double(long) / (ratio >= 1 ? ratio : 1 / ratio)
                #expect(abs(Double(short) - expectedShort) <= 0.5 + 1e-9, "\(width)×\(height) → \(filed)")
            }
        }
    }

    // MARK: Longest-edge rule (Codex, fallback)

    @Test(arguments: [
        (size(4096, 2560), size(2048, 1280)),
        (size(1000, 3000), size(683, 2048)),
        (size(2048, 100), size(2048, 100)),
        (size(2049, 2049), size(2048, 2048)),
        (size(640, 480), size(640, 480)),
    ])
    func longestEdgeFitsWithin2048(original: PixelSize, filed: PixelSize) {
        #expect(MediaScaleTarget.codex.imageSize(for: original) == filed)
        #expect(MediaScaleTarget.fallback.imageSize(for: original) == filed)
    }

    @Test func neverScalesUpAndLeavesEmptySizesAlone() {
        for target in [MediaScaleTarget.claudeStandard, .claudeHighResolution, .codex, .fallback] {
            #expect(target.imageSize(for: Self.size(10, 10)) == Self.size(10, 10))
            #expect(target.imageSize(for: Self.size(1, 1)) == Self.size(1, 1))
            #expect(target.imageSize(for: Self.size(0, 0)) == Self.size(0, 0))
            #expect(target.videoSize(for: Self.size(101, 51)) == Self.size(101, 51), "a fitting movie isn't re-encoded")
        }
    }

    // MARK: Videos

    @Test func videoFramesFollowTheImageRuleRoundedDownToEvenSides() {
        #expect(MediaScaleTarget.claudeHighResolution.videoSize(for: Self.size(3840, 2160)) == Self.size(2576, 1448))
        #expect(MediaScaleTarget.claudeStandard.videoSize(for: Self.size(1920, 1080)) == Self.size(1456, 818))
        #expect(MediaScaleTarget.claudeStandard.videoSize(for: Self.size(1075, 1520)) == Self.size(924, 1306))
        #expect(MediaScaleTarget.fallback.videoSize(for: Self.size(4097, 2049)) == Self.size(2048, 1024))
        #expect(MediaScaleTarget.codex.videoSize(for: Self.size(3024, 1964)) == Self.size(2048, 1330))
        #expect(MediaScaleTarget.fallback.size(for: Self.size(3000, 3), kind: .video) == Self.size(2048, 2))
        #expect(MediaScaleTarget.fallback.size(for: Self.size(3000, 1501), kind: .image) == Self.size(2048, 1025))
        #expect(MediaScaleTarget.fallback.size(for: Self.size(3000, 1501), kind: .video) == Self.size(2048, 1024))
    }

    // MARK: Which target

    @Test(arguments: [
        ("opus", ClaudeVisionTier.highResolution),
        ("sonnet", .highResolution),
        ("fable", .highResolution),
        ("mythos", .highResolution),
        ("Opus", .highResolution),
        ("opus[1m]", .highResolution),
        ("opusplan", .highResolution),
        ("haiku", .standard),
        ("claude-opus-5-5", .highResolution),
        ("claude-opus-4-8", .highResolution),
        ("claude-opus-4-7", .highResolution),
        ("claude-opus-4-6", .standard),
        ("claude-sonnet-5", .highResolution),
        ("claude-sonnet-4-6", .standard),
        ("claude-sonnet-4-5-20250929", .standard),
        ("claude-haiku-4-5", .standard),
        ("claude-3-5-sonnet-20241022", .standard),
        ("claude-fable-5-1", .highResolution),
        ("us.anthropic.claude-opus-4-7", .highResolution),
        ("anthropic.claude-opus-4-6-v1", .standard),
        ("default", .standard),
        ("gpt-6.1-sol", .standard),
        ("", .standard),
    ])
    func claudeModelsMapToTheirTier(model: String, tier: ClaudeVisionTier) {
        #expect(ClaudeVisionTier.of(model: model) == tier)
    }

    @Test func eachToolGetsItsTarget() {
        #expect(MediaScaleTarget.forTool(AIToolSettings(tool: "claude", model: "opus")) == .claudeHighResolution)
        #expect(MediaScaleTarget.forTool(AIToolSettings(tool: "Claude", model: "haiku")) == .claudeStandard)
        #expect(MediaScaleTarget.forTool(AIToolSettings(tool: "claude")) == .claudeStandard, "no model: the standard tier")
        #expect(MediaScaleTarget.forTool(AIToolSettings(tool: "codex", model: "gpt-6.1-sol")) == .codex)
        #expect(MediaScaleTarget.forTool(AIToolSettings(tool: "antigravity", model: "gemini-3.8-flash-high")) == .fallback)
        #expect(MediaScaleTarget.forTool(nil) == .fallback)
        #expect(MediaScaleTarget.codex.audience == "Codex" && MediaScaleTarget.fallback.audience == "AI")
        #expect(MediaScaleTarget.claudeStandard.audience == "Claude")
    }

    @Test func parsesTheCLIsJSON() {
        #expect(
            AIToolSettings
                .parse(#"{"tool":"claude","model":"sonnet","effort":"medium"}"#) == AIToolSettings(tool: "claude", model: "sonnet")
        )
        #expect(AIToolSettings.parse(#"{"provider":"codex","model":""}"#) == AIToolSettings(tool: "codex"))
        #expect(AIToolSettings.parse(#"{"model":"opus"}"#) == nil)
        #expect(AIToolSettings.parse(#"{"tool":"  "}"#) == nil)
        #expect(AIToolSettings.parse("claude\nmodel\tsonnet") == nil, "the plain-text form isn't JSON")
        #expect(AIToolSettings.parse("") == nil)
    }

    // MARK: Detection through hotsheet-cli

    private let cli = URL(fileURLWithPath: "/bin/hotsheet-cli")
    private let store = URL(fileURLWithPath: "/stores/demo.hs2")

    @Test func detectsTheProjectsToolWithAISettingsGet() throws {
        let runner = FakeRunner(results: [
            ProcessResult(exitCode: 0, stdout: #"{"tool":"claude","model":"opus","effort":"high"}"# + "\n", stderr: ""),
        ])
        let client = HotSheetCLIClient(executable: cli, storePath: store, runner: runner, baseEnvironment: ["HOTSHEET_ACTOR_ROLE": "ai"])
        #expect(MediaScaleTarget.detect(using: client) == .claudeHighResolution)
        #expect(runner.calls.first?.arguments == [
            "-C", "/stores/demo.hs2", "ai-settings", "--actor-role=human", "--actor-id=ux-review", "get", "--json",
        ])
        #expect(runner.calls.first?.environment["HOTSHEET_ACTOR_ROLE"] == nil)
    }

    @Test(arguments: [
        ProcessResult(exitCode: 2, stdout: "", stderr: "error: unrecognized subcommand 'ai-settings'"), // an older CLI
        ProcessResult(exitCode: 1, stdout: "", stderr: "Error: not a Hot Sheet store"),
        ProcessResult(exitCode: 0, stdout: "claude\nmodel\tsonnet\n", stderr: ""),
        ProcessResult(exitCode: 0, stdout: "", stderr: ""),
    ])
    func anyCLIFailureFallsBackTo2048(result: ProcessResult) throws {
        let client = HotSheetCLIClient(executable: cli, storePath: store, runner: FakeRunner(results: [result]), baseEnvironment: [:])
        #expect(throws: HotSheetError.self) { _ = try client.aiSettings() }
        #expect(MediaScaleTarget.detect(using: client) == .fallback)
    }

    @Test func clientsThatCantTellFallBack() {
        let fake = FakeHotSheetClient()
        #expect(MediaScaleTarget.detect(using: fake) == .fallback)
        fake.aiTool = .failure(HotSheetError.cliNotFound)
        #expect(MediaScaleTarget.detect(using: fake) == .fallback)
        fake.aiTool = .success(AIToolSettings(tool: "codex"))
        #expect(MediaScaleTarget.detect(using: fake) == .codex)
    }

    // MARK: Bundles and the Submit Review list

    @Test func scalingABundleChangesSizesNotAnnotations() {
        let big = MediaItem(
            id: "m1",
            filename: "big.png",
            kind: .image,
            pixelWidth: 3840,
            pixelHeight: 2160,
            capturedAt: Date(timeIntervalSince1970: 0)
        )
        let small = MediaItem(
            id: "m2",
            filename: "small.png",
            kind: .image,
            pixelWidth: 800,
            pixelHeight: 600,
            capturedAt: Date(timeIntervalSince1970: 0)
        )
        var movie = TestSupport.video("m3", filename: "clip.mov")
        movie.pixelWidth = 3840
        movie.pixelHeight = 2160
        let annotation = Annotation(id: "a1", mediaId: "m1", shape: .rect(NormRect(x: 1234, y: 4321, width: 2000, height: 1000)), note: "")
        let bundle = TestSupport.bundle(media: [big, small, movie], annotations: [annotation])
        let (scaled, from) = MediaScaleTarget.claudeHighResolution.apply(to: bundle)
        #expect(from == ["m1": Self.size(3840, 2160), "m3": Self.size(3840, 2160)])
        #expect(scaled.media.map { Self.size($0.pixelWidth, $0.pixelHeight) } == [
            Self.size(2576, 1449),
            Self.size(800, 600),
            Self.size(2576, 1448),
        ])
        #expect(scaled.annotations == bundle.annotations)
        #expect(scaled.validate().isEmpty)
    }

    @Test func thePreviewShowsTheFiledSizeAndWhoItIsScaledFor() {
        let image = MediaItem(
            id: "m1",
            filename: "shot.png",
            kind: .image,
            pixelWidth: 3200,
            pixelHeight: 2000,
            capturedAt: Date(timeIntervalSince1970: 0)
        )
        let plain = MediaItem(
            id: "m2",
            filename: "plain.png",
            kind: .image,
            pixelWidth: 800,
            pixelHeight: 600,
            capturedAt: Date(timeIntervalSince1970: 0)
        )
        let bundle = TestSupport.bundle(media: [image, plain])
        let crop = DraftEdits(crops: ["shot.png": PixelRect(x: 0, y: 0, width: 3000, height: 1000)])

        let off = SubmissionPreview(bundle, edits: DraftEdits())
        #expect(off.media["m1"]?.sizeText == "3200×2000" && off.media["m1"]?.scaledFrom == nil)

        let codex = SubmissionPreview(bundle, edits: DraftEdits(), scale: .codex)
        #expect(codex.media["m1"]?.sizeText == "2048×1280 scaled for Codex")
        #expect(codex.media["m1"]?.scaledFrom == Self.size(3200, 2000) && codex.media["m1"]?.scaledFor == "Codex")
        #expect(codex.media["m2"]?.sizeText == "800×600" && codex.media["m2"]?.scaledFor == nil)

        let cropped = SubmissionPreview(bundle, edits: crop, scale: .claudeStandard)
        // 3000×1000 cropped, then Claude's standard tier: 2145+ tokens → the largest that fits.
        let filed = MediaScaleTarget.claudeStandard.imageSize(for: Self.size(3000, 1000))
        #expect(cropped.media["m1"]?.sizeText == "\(filed.width)×\(filed.height) cropped, scaled for Claude")
        #expect(cropped.media["m1"]?.scaledFrom == Self.size(3000, 1000))
    }
}
