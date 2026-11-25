import Foundation
import CoreGraphics
import Vision

/// A piece of recognized text with its position in normalized image coordinates (origin bottom-left, as Vision reports).
struct OCRFragment: Sendable, Equatable {
    var text: String
    var minX: Double
    var midY: Double
    var height: Double
}

/// Rebuilds receipt lines from OCR fragments. Vision often returns a receipt's left column (labels)
/// and right column (prices) as separate observations; grouping by vertical position puts
/// "TOTAL" and "12.34" back on the same line.
enum OCRLineAssembler {
    static func lines(from fragments: [OCRFragment]) -> [String] {
        let sorted = fragments
            .filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
            .sorted { $0.midY > $1.midY }
        var groups: [[OCRFragment]] = []
        for f in sorted {
            if let last = groups.last, let first = last.first {
                let average = last.map(\.midY).reduce(0, +) / Double(last.count)
                let tolerance = max(first.height, f.height) * 0.5
                if abs(average - f.midY) <= tolerance {
                    groups[groups.count - 1].append(f)
                    continue
                }
            }
            groups.append([f])
        }
        return groups.map { $0.sorted { $0.minX < $1.minX }.map(\.text).joined(separator: "  ") }
    }
}

enum ReceiptOCRError: Error, LocalizedError {
    case noTextFound
    var errorDescription: String? { "No text was found in this image." }
}

/// Abstraction so the scanner can be tested with a fake recognizer.
protocol ReceiptTextRecognizing: Sendable {
    func recognizeText(in image: CGImage) async throws -> [String]
}

/// On-device text recognition with Apple Vision. `VNRecognizeTextRequest` runs entirely on the
/// device; no image or text leaves the iPhone and no network is required.
struct VisionReceiptOCRService: ReceiptTextRecognizing {
    var logger: any AppLogger = DiagnosticsService.shared

    func recognizeText(in image: CGImage) async throws -> [String] {
        let token = logger.begin(.receiptOCR)
        do {
            let lines = try await readLines(in: image)
            logger.end(token)
            return lines
        } catch {
            logger.end(token, error: error)
            throw error
        }
    }

    private func readLines(in image: CGImage) async throws -> [String] {
        let lines = try await Task.detached(priority: .userInitiated) { () throws -> [String] in
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
            try handler.perform([request])
            let fragments = (request.results ?? []).compactMap { observation -> OCRFragment? in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                let box = observation.boundingBox
                return OCRFragment(text: candidate.string, minX: Double(box.minX), midY: Double(box.midY), height: Double(box.height))
            }
            return OCRLineAssembler.lines(from: fragments)
        }.value
        guard !lines.isEmpty else { throw ReceiptOCRError.noTextFound }
        return lines
    }
}
