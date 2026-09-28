import AppKit
import AVFoundation

// Temporary (round 6 exploration): swift scripts/ci-frames.swift <video> <out.png> <start> <step> <count>
// One contact sheet of `count` frames, 8 across. Removed before the PR is final.
let args = CommandLine.arguments
let asset = AVURLAsset(url: URL(fileURLWithPath: args[1]))
let out = args[2]
let start = Double(args[3]) ?? 0
let step = Double(args[4]) ?? 0.2
let count = Int(args[5]) ?? 24
let generator = AVAssetImageGenerator(asset: asset)
generator.appliesPreferredTrackTransform = true
generator.requestedTimeToleranceBefore = .zero
generator.requestedTimeToleranceAfter = .zero
generator.maximumSize = CGSize(width: 240, height: 520)
var images: [CGImage] = []
for index in 0..<count {
    let time = CMTime(seconds: start + Double(index) * step, preferredTimescale: 600)
    if let image = try? generator.copyCGImage(at: time, actualTime: nil) { images.append(image) }
}
guard let first = images.first else { print("no frames"); exit(1) }
let width = first.width, height = first.height
let cols = min(images.count, 8)
let rows = (images.count + cols - 1) / cols
let context = CGContext(
    data: nil, width: width * cols, height: height * rows, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!
for (index, image) in images.enumerated() {
    let col = index % cols, row = index / cols
    context.draw(image, in: CGRect(x: col * width, y: (rows - 1 - row) * height, width: width, height: height))
}
let rep = NSBitmapImageRep(cgImage: context.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("sheet", out, images.count, "frames of", asset.duration.seconds, "s")
