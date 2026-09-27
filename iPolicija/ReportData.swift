import Foundation
import CoreLocation

enum OffenceType: String, CaseIterable, Identifiable {
    case blockedPavement = "Blocked pavement / footpath"
    case blockedBikeLane = "Blocked bike lane"
    case blockedCrosswalk = "Blocked pedestrian crossing"
    case disabledSpot = "Parked in disabled spot"
    case blockedDriveway = "Blocking driveway / exit"

    var id: String { rawValue }

    /// Answer to "Kas įvyko?" on epolicija (must match the option text exactly).
    var formOption: String {
        switch self {
        case .blockedPavement, .blockedBikeLane, .blockedCrosswalk:
            return "Neleistinoje vietoje pastatyta transporto priemonė"
        case .disabledSpot:
            return "Transporto priemonė, nepažymėta skiriamuoju ženklu „Neįgalusis“ arba neįgaliųjų asmenų automobilių statymo kortele, pastatyta neįgaliųjų vietoje"
        case .blockedDriveway:
            return "Trukdymas transporto priemonių ar kitų eismo dalyvių eismui"
        }
    }

    /// Answer to "Apibūdinkite vietą".
    var placeType: String {
        switch self {
        case .blockedPavement: return "Šaligatvis"
        case .disabledSpot: return "Automobilių stovėjimo aikštelė"
        case .blockedBikeLane, .blockedCrosswalk, .blockedDriveway: return "Gatvė"
        }
    }

    /// Lithuanian phrase used in the description: "Transporto priemonė ABC123 <phrase> adresu …"
    var descriptionPhrase: String {
        switch self {
        case .blockedPavement: return "pastatyta ant šaligatvio ir trukdo pėstiesiems"
        case .blockedBikeLane: return "pastatyta dviračių take"
        case .blockedCrosswalk: return "pastatyta ant pėsčiųjų perėjos"
        case .disabledSpot: return "pastatyta neįgaliųjų vietoje be neįgaliojo kortelės"
        case .blockedDriveway: return "užstoja įvažiavimą / išvažiavimą"
        }
    }
}

enum LocationSource: String {
    case photo = "from photo"
    case device = "current location"
    case none = "unknown"
}

struct ReportData {
    var plate: String = ""
    var offence: OffenceType = .blockedPavement
    var city: String = ""
    var street: String = ""
    var house: String = ""
    var coordinate: CLLocationCoordinate2D?
    var locationSource: LocationSource = .none
    var date: Date = Date()
    /// Optional extra details appended to the generated description.
    var note: String = ""

    mutating func apply(_ address: ResolvedAddress, source: LocationSource) {
        city = address.city
        street = address.street
        house = address.house
        coordinate = address.coordinate
        locationSource = source
    }

    var addressText: String {
        [street.isEmpty ? nil : (house.isEmpty ? street : "\(street) \(house)"), city.isEmpty ? nil : city]
            .compactMap { $0 }
            .joined(separator: ", ")
    }

    /// Text for "Įvykio aplinkybės".
    var descriptionText: String {
        var text = "Transporto priemonė \(plate) \(offence.descriptionPhrase)"
        if !addressText.isEmpty { text += " adresu \(addressText)" }
        text += ". Pažeidimą mačiau pats ir nufotografavau, nuotrauka pridėta."
        let extra = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !extra.isEmpty { text += " " + extra }
        return text
    }
}
