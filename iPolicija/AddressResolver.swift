import Foundation
import CoreLocation

/// Address split the way epolicija's "Vieta" step wants it.
struct ResolvedAddress {
    var city: String        // "Vietovė", e.g. "Vilnius"
    var street: String      // "Gatvė", e.g. "J. Basanavičiaus g."
    var house: String       // "Namo numeris", e.g. "12A"
    var coordinate: CLLocationCoordinate2D

    /// What to type into the form's street search.
    var streetSearchText: String { AddressResolver.streetSearchText(for: street) }

    var display: String {
        [street.isEmpty ? nil : (house.isEmpty ? street : "\(street) \(house)"), city.isEmpty ? nil : city]
            .compactMap { $0 }
            .joined(separator: ", ")
    }
}

enum AddressResolver {
    /// The form asks for only a surname fragment for streets named after people
    /// ("J. Basanavičiaus g." → "Basana"); street types and initials are dropped.
    static func streetSearchText(for street: String) -> String {
        let suffixes: Set<String> = ["g.", "pr.", "al.", "pl.", "skg.", "kel.", "tak.", "a.", "krant."]
        let words = street
            .split(separator: " ")
            .map(String.init)
            .filter { !suffixes.contains($0.lowercased()) }
            .filter { !($0.count <= 3 && $0.hasSuffix(".")) }   // initials like "J." or "M. K."
        guard let longest = words.max(by: { $0.count < $1.count }) else { return street }
        return String(longest.prefix(6))
    }

    /// Reverse-geocodes coordinates using Lithuanian names (street types like "g.", "pr.").
    static func resolve(_ location: CLLocation) async -> ResolvedAddress? {
        let placemarks = try? await CLGeocoder().reverseGeocodeLocation(
            location,
            preferredLocale: Locale(identifier: "lt_LT")
        )
        guard let p = placemarks?.first else { return nil }
        return ResolvedAddress(
            city: p.locality ?? p.subAdministrativeArea ?? "",
            street: p.thoroughfare ?? "",
            house: p.subThoroughfare ?? "",
            coordinate: location.coordinate
        )
    }
}
