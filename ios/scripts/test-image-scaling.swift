// Tests for ImageScaling — how much of a phone photo travels over the LAN.
//
// Run via ./ios/scripts/run-tests.sh. UIKit-free on purpose so it compiles and
// runs on the host.
import CoreGraphics
import Foundation

private var failures = 0

private func check(_ condition: Bool, _ what: String) {
    if condition {
        print("  ok   \(what)")
    } else {
        failures += 1
        print("  FAIL \(what)")
    }
}

@main
enum ImageScalingTests {
static func main() {

let maxDim = ImageScaling.maxDimension

print("ImageScaling.targetSize")
let small = CGSize(width: 800, height: 600)
check(ImageScaling.targetSize(for: small) == small,
      "an image already within the limit is untouched")

// A 4032x3024 camera photo is the case this exists for.
let photo = ImageScaling.targetSize(for: CGSize(width: 4032, height: 3024))
check(max(photo.width, photo.height) == maxDim, "a camera photo is reduced to the limit")
check(abs(photo.width / photo.height - 4032.0 / 3024.0) < 0.01, "aspect ratio is preserved")

let portrait = ImageScaling.targetSize(for: CGSize(width: 1200, height: 3000))
check(portrait.height == maxDim, "the LONGEST edge is what gets clamped, not the width")
check(portrait.width < maxDim, "the short edge scales with it")

check(ImageScaling.targetSize(for: CGSize(width: maxDim, height: maxDim)) == CGSize(width: maxDim, height: maxDim),
      "exactly at the limit is untouched")

// Degenerate shapes must not round an edge away to nothing.
let panorama = ImageScaling.targetSize(for: CGSize(width: 8000, height: 3))
check(panorama.width == maxDim && panorama.height >= 1,
      "an extreme panorama keeps at least one pixel of height")

check(ImageScaling.targetSize(for: .zero) == .zero, "a zero size is returned as-is, not divided by")

// Never upscale: more bytes, no more information.
let tiny = CGSize(width: 32, height: 32)
check(ImageScaling.targetSize(for: tiny) == tiny, "a tiny image is not blown up")

// The limit is a parameter so the rule can be checked independently of its value.
check(ImageScaling.targetSize(for: CGSize(width: 1000, height: 500), maxDimension: 100)
        == CGSize(width: 100, height: 50),
      "scaling is proportional at an arbitrary limit")

if failures > 0 {
    print("\n\(failures) failure(s)")
    exit(1)
}
print("\nall passed")
}
}
