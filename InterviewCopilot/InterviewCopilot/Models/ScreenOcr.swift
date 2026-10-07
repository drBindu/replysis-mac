import Foundation
import CoreGraphics
import Vision

/// Reads the words on a screen with the Vision framework that ships with macOS.
///
/// Why it exists: on a weak connection a screenshot takes seconds to upload, and the speech already uses much
/// of what the line has. The words on the screen are a few kilobytes, so they can go ahead of the question on
/// any line and the question is answered from a screen that was read before it was asked. Nothing is installed
/// and nothing is sent anywhere to do the reading; it happens on this Mac.
///
/// A fast line keeps sending the picture, which carries what text cannot (a diagram, colour, a chart). This is
/// for the lines where the picture is the thing that makes the answer late.
enum ScreenOcr {
    /// Longest side read. A 5K display is 14 megapixels; reading it whole costs seconds and buys nothing, since
    /// body text is already well above what the reader needs at this size.
    private static let maxSide = 3200

    /// The words on a capture, laid out for reading, or nil when there are none worth sending or the reader
    /// failed. Takes a second or so on a busy screen: call it off the main thread.
    static func read(_ image: CGImage) -> String? {
        let source = scaledIfLarge(image)
        let width = Double(source.width), height = Double(source.height)
        guard width > 0, height > 0 else { return nil }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        // Code is not prose: "correcting" an identifier or a bracket is how a wrong answer is born.
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]

        let handler = VNImageRequestHandler(cgImage: source, options: [:])
        do { try handler.perform([request]) } catch {
            dlog("SCREEN: reading the screen's words failed: \(error.localizedDescription)", tag: "SCREEN")
            return nil
        }
        guard let observations = request.results else { return nil }

        var words: [OcrWord] = []
        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let line = candidate.string
            // One box per word, so the layout can tell a gutter between panels from a space between words.
            var index = line.startIndex
            while index < line.endIndex {
                if line[index].isWhitespace { index = line.index(after: index); continue }
                var end = index
                while end < line.endIndex, !line[end].isWhitespace { end = line.index(after: end) }
                let range = index..<end
                if let box = try? candidate.boundingBox(for: range)?.boundingBox {
                    // Vision's boxes are 0 to 1 from the BOTTOM left; the layout reads pixels from the top left.
                    words.append(OcrWord(text: String(line[range]),
                                         x: box.minX * width, y: (1 - box.maxY) * height,
                                         w: box.width * width, h: box.height * height))
                }
                index = end
            }
        }

        let text = OcrLayout.fit(OcrLayout.toText(words))
        let letters = text.reduce(0) { $0 + ($1.isWhitespace ? 0 : 1) }
        return letters < OcrLayout.minUsefulChars ? nil : text
    }

    private static func scaledIfLarge(_ image: CGImage) -> CGImage {
        let longest = max(image.width, image.height)
        guard longest > maxSide else { return image }
        let scale = Double(maxSide) / Double(longest)
        let w = max(1, Int(Double(image.width) * scale)), h = max(1, Int(Double(image.height) * scale))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? image
    }
}
