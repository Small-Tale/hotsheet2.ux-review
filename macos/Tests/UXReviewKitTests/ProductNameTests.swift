import Testing
import UXReviewKit

struct ProductNameTests {
    @Test func fullNameEndsWithTheShortName() {
        #expect(ProductName.full == "Hot Sheet 2 UX Review")
        #expect(ProductName.short == "UX Review")
        #expect(ProductName.full.hasSuffix(ProductName.short))
    }
}
