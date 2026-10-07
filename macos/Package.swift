// swift-tools-version: 6.0
import PackageDescription

// UXReviewKit is the platform-neutral-ish core of the macOS app: the review bundle model
// (mirrors spec/review-bundle.schema.json), ticket composition, and the Hot Sheet client.
// It has no AppKit dependency so its logic stays unit-testable from `swift test`.
let package = Package(
    name: "UXReviewKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "UXReviewKit", targets: ["UXReviewKit"]),
    ],
    targets: [
        .target(name: "UXReviewKit"),
        // Tests read the shared example from ../spec/examples so the spec cannot drift.
        .testTarget(name: "UXReviewKitTests", dependencies: ["UXReviewKit"]),
    ]
)
