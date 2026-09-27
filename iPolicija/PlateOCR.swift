import Vision
import UIKit
import ImageIO

/// Reads licence plates from a photo.
///
/// Known Lithuanian formats rank first, with common OCR mix-ups corrected (0↔O, 1↔I, 8↔B…).
/// Anything else plate-shaped (foreign, personalised, motorcycles…) is offered as a lower-ranked
/// candidate, so the UI can show it as a one-tap alternative.
enum PlateOCR {

    /// Calls back with plate candidates (best first) and every piece of text Vision read (for debugging).
    static func recognizePlate(in image: UIImage, completion: @escaping ([String], [String]) -> Void) {
        guard let cgImage = image.cgImage else {
            completion([], ["(no image data)"])
            return
        }

        let request = VNRecognizeTextRequest { request, _ in
            let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
            let texts = observations.compactMap { $0.topCandidates(1).first?.string }
            completion(rank(observations), texts)
        }
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.01   // plates are often small in the frame

        // iPhone photos are stored sideways with an orientation flag; without passing it,
        // Vision reads the text rotated 90° and finds nothing.
        let handler = VNImageRequestHandler(
            cgImage: cgImage,
            orientation: CGImagePropertyOrientation(image.imageOrientation),
            options: [:]
        )
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try handler.perform([request])
            } catch {
                completion([], ["(OCR error: \(error.localizedDescription))"])
            }
        }
    }

    // MARK: - Ranking

    private struct Source {
        let text: String
        let confidence: Double
        let height: Double
    }

    /// Up to 4 distinct plate candidates, best first.
    static func rank(_ observations: [VNRecognizedTextObservation]) -> [String] {
        var sources: [Source] = []

        // Each text block on its own (top 3 readings).
        for observation in observations {
            for candidate in observation.topCandidates(3) {
                sources.append(Source(
                    text: candidate.string,
                    confidence: Double(candidate.confidence),
                    height: Double(observation.boundingBox.height)
                ))
            }
        }

        // Blocks on the same line joined — letters and digits often come back separately.
        for line in lines(observations) where line.count > 1 {
            let tops = line.compactMap { $0.topCandidates(1).first }
            sources.append(Source(
                text: tops.map(\.string).joined(separator: " "),
                confidence: Double(tops.map(\.confidence).min() ?? 0),
                height: Double(line.map(\.boundingBox.height).max() ?? 0)
            ))
        }

        var best: [String: Double] = [:]
        for source in sources {
            for (plate, formatScore) in matches(in: source.text) {
                // Bigger text is more likely the plate than a sign in the background.
                let score = formatScore + 0.3 * source.confidence + min(source.height * 2, 0.4)
                best[plate] = max(best[plate] ?? -1, score)
            }
        }

        return best
            .sorted { $0.value > $1.value }
            .prefix(4)
            .map(\.key)
    }

    /// Groups text blocks that sit next to each other on the same row, left to right.
    private static func lines(_ observations: [VNRecognizedTextObservation]) -> [[VNRecognizedTextObservation]] {
        var lines: [[VNRecognizedTextObservation]] = []
        for observation in observations.sorted(by: { $0.boundingBox.minX < $1.boundingBox.minX }) {
            let box = observation.boundingBox
            if let index = lines.firstIndex(where: { line in
                let last = line[line.count - 1].boundingBox
                let height = max(last.height, box.height)
                return abs(last.midY - box.midY) < height * 0.5 && box.minX - last.maxX < height * 2
            }) {
                lines[index].append(observation)
            } else {
                lines.append([observation])
            }
        }
        return lines
    }

    // MARK: - Formats

    /// A plate format: regex capture groups, whether each group must be letters ("L") or digits ("D"),
    /// a base score, and an extra check on the corrected plate (e.g. EV plates start with EA/EV).
    private struct Format {
        let regex: NSRegularExpression
        let kinds: [Character]
        let score: Double
        let accept: (String) -> Bool
    }

    private static let an = "[A-Z0-9]"
    private static let sep = "[\\s\\-·.]?"
    /// The screw/separator between letters and digits is often read as an extra "I" ("LMPI 854").
    private static let junkSep = "[\\s\\-·.|!I1]{0,3}"

    private static func format(_ pattern: String, _ kinds: [Character], _ score: Double,
                               accept: @escaping (String) -> Bool = { _ in true }) -> Format {
        Format(
            regex: try! NSRegularExpression(pattern: "(?<![A-Z0-9])" + pattern + "(?![A-Z0-9])"),
            kinds: kinds,
            score: score,
            accept: accept
        )
    }

    /// Lithuanian formats (Regitra): standard, electric (EV/EA), taxi/historic/temporary, military.
    private static let formats: [Format] = [
        format("(\(an){3})\(junkSep)(\(an){3})", ["L", "D"], 1.0),                                   // ABC 123
        format("(\(an){2})\(sep)(\(an){4})", ["L", "D"], 1.0) { $0.hasPrefix("EA") || $0.hasPrefix("EV") }, // EA 1234
        format("(\(an))\(sep)(\(an){4,5})", ["L", "D"], 0.9) { "THP".contains($0.prefix(1)) },       // T12345, H1234, P12345
        format("(\(an){2})\(sep)(\(an){3})\(sep)(\(an))", ["L", "D", "L"], 0.9) { $0.hasPrefix("LK") }, // LK 123 A
    ]

    /// Score for anything else plate-shaped (foreign, personalised).
    private static let genericScore = 0.5
    /// Each OCR correction makes a format match less certain.
    private static let correctionPenalty = 0.15

    /// All plate-shaped matches in the text with their format score.
    static func matches(in text: String) -> [(String, Double)] {
        let upper = text.uppercased()
        let range = NSRange(upper.startIndex..., in: upper)
        var result: [(String, Double)] = []

        for format in formats {
            for match in format.regex.matches(in: upper, range: range) {
                var plate = ""
                var valid = true
                var fixes = 0
                for (index, kind) in format.kinds.enumerated() {
                    guard let groupRange = Range(match.range(at: index + 1), in: upper) else {
                        valid = false
                        break
                    }
                    let raw = Array(upper[groupRange])
                    let fixed = raw.map { kind == "L" ? (toLetter[$0] ?? $0) : (toDigit[$0] ?? $0) }
                    fixes += zip(raw, fixed).filter { $0.0 != $0.1 }.count
                    valid = valid && fixed.allSatisfy { $0.isASCII && (kind == "L" ? $0.isLetter : $0.isNumber) }
                    plate += String(fixed)
                }
                if valid && format.accept(plate) {
                    result.append((plate, format.score - correctionPenalty * Double(fixes)))
                }
            }
        }

        result += genericPlates(in: upper).map { ($0, genericScore) }
        return result
    }

    /// 4–8 letters/digits with at least one of each, from up to 3 adjacent groups
    /// ("WA 12345", "AB-1234", "B AB 1234", "L4URA").
    private static func genericPlates(in text: String) -> [String] {
        let tokens = text
            .split(whereSeparator: { !($0.isASCII && ($0.isLetter || $0.isNumber)) })
            .map(String.init)
        var plates: [String] = []
        for start in tokens.indices {
            var joined = ""
            for end in start..<min(start + 3, tokens.count) {
                joined += tokens[end]
                if (4...8).contains(joined.count),
                   joined.contains(where: \.isLetter),
                   joined.contains(where: \.isNumber) {
                    plates.append(joined)
                }
            }
        }
        return plates
    }

    private static let toLetter: [Character: Character] = [
        "0": "O", "1": "I", "2": "Z", "4": "A", "5": "S", "6": "G", "8": "B"
    ]
    private static let toDigit: [Character: Character] = [
        "O": "0", "Q": "0", "D": "0", "I": "1", "L": "1", "Z": "2", "S": "5", "G": "6", "T": "7", "B": "8"
    ]
}

extension CGImagePropertyOrientation {
    init(_ orientation: UIImage.Orientation) {
        switch orientation {
        case .up: self = .up
        case .upMirrored: self = .upMirrored
        case .down: self = .down
        case .downMirrored: self = .downMirrored
        case .left: self = .left
        case .leftMirrored: self = .leftMirrored
        case .right: self = .right
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}
