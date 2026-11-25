import XCTest
@testable import SeatSixApp

final class SeatSixMaterialTests: XCTestCase {
    func testPlatformFallbackDoesNotRequireLiquidGlassOnOlderMacs() {
        XCTAssertEqual(policy(supportsGlass: true).surface, .liquidGlass)
        XCTAssertEqual(policy(supportsGlass: false).surface, .material)
    }

    func testReadabilityPreferencesOverrideBothKindsOfTranslucency() {
        for supportsGlass in [true, false] {
            for reduceMotion in [true, false] {
                XCTAssertEqual(policy(supportsGlass: supportsGlass, reduceTransparency: true, reduceMotion: reduceMotion).surface, .opaque)
                let highContrast = policy(supportsGlass: supportsGlass, increasedContrast: true, reduceMotion: reduceMotion)
                XCTAssertEqual(highContrast.surface, .opaque)
                XCTAssertTrue(highContrast.emphasizesBoundary)
                XCTAssertEqual(policy(supportsGlass: supportsGlass, reduceTransparency: true,
                                      increasedContrast: true, reduceMotion: reduceMotion).surface, .opaque)
            }
        }
    }

    func testReducedMotionDisablesAnimationWithoutDiscardingReadableSurfaceChoice() {
        for supportsGlass in [true, false] {
            for reduceTransparency in [true, false] {
                for increasedContrast in [true, false] {
                    let normal = policy(supportsGlass: supportsGlass, reduceTransparency: reduceTransparency,
                                        increasedContrast: increasedContrast)
                    let reduced = policy(supportsGlass: supportsGlass, reduceTransparency: reduceTransparency,
                                         increasedContrast: increasedContrast, reduceMotion: true)
                    XCTAssertTrue(normal.allowsAnimation)
                    XCTAssertFalse(reduced.allowsAnimation)
                    XCTAssertEqual(normal.surface, reduced.surface)
                    XCTAssertEqual(normal.emphasizesBoundary, reduced.emphasizesBoundary)
                }
            }
        }
    }

    private func policy(supportsGlass: Bool, reduceTransparency: Bool = false,
                        increasedContrast: Bool = false, reduceMotion: Bool = false) -> SeatSixMaterialPolicy {
        SeatSixMaterialPolicy(supportsLiquidGlass: supportsGlass, reduceTransparency: reduceTransparency,
                              increasedContrast: increasedContrast, reduceMotion: reduceMotion)
    }
}
