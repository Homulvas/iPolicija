import Foundation
import ImageIO
import CoreLocation

/// Location and capture time embedded in a photo's EXIF/GPS metadata.
struct PhotoMetadata {
    var location: CLLocation?
    var date: Date?

    static func read(from data: Data) -> PhotoMetadata {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return PhotoMetadata()
        }

        var meta = PhotoMetadata()

        if let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any],
           var lat = gps[kCGImagePropertyGPSLatitude] as? Double,
           var lon = gps[kCGImagePropertyGPSLongitude] as? Double {
            if (gps[kCGImagePropertyGPSLatitudeRef] as? String) == "S" { lat = -lat }
            if (gps[kCGImagePropertyGPSLongitudeRef] as? String) == "W" { lon = -lon }
            let accuracy = gps[kCGImagePropertyGPSHPositioningError] as? Double ?? 0
            meta.location = CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                altitude: 0,
                horizontalAccuracy: accuracy,
                verticalAccuracy: -1,
                timestamp: Date()
            )
        }

        if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let original = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            if let offset = exif[kCGImagePropertyExifOffsetTimeOriginal] as? String {
                // e.g. "2026:09:26 21:14:03" + "+03:00"
                formatter.dateFormat = "yyyy:MM:dd HH:mm:ssxxx"
                meta.date = formatter.date(from: original + offset)
            } else {
                formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
                formatter.timeZone = .current
                meta.date = formatter.date(from: original)
            }
        }

        return meta
    }
}
