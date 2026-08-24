import Foundation

// Nottingham Express Transit trams via Traveline's Passenger API (keyless HAL JSON).
// NET stopped publishing vehicle tracking, so visits are timetable-derived today;
// the real-time fields are decoded anyway and light up if NET ever resumes.

private struct NETVisits: Decodable {
    struct Embedded: Decodable {
        struct Visit: Decodable {
            let destinationName: String?
            let aimedDepartureTime: String?
            let expectedDepartureTime: String?
            let aimedArrivalTime: String?
            let expectedArrivalTime: String?
            let isRealTime: Bool?
            let cancelled: Bool?
        }
        let visits: [Visit]
        enum CodingKeys: String, CodingKey { case visits = "timetable:visit" }
    }
    let _embedded: Embedded
}

func netTramBoard(code: String) async throws -> [Service] {
    let url = URL(string: "https://traveline.arcticapi.com/network/stops/\(code)/visits")!
    let (data, response) = try await URLSession.shared.data(from: url)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
    let iso = ISO8601DateFormatter()
    let london = clock(for: Network.netTrams.timeZone)
    return try JSONDecoder().decode(NETVisits.self, from: data)._embedded.visits
        .compactMap { v -> (Date, Service)? in
            guard let aimedRaw = v.aimedDepartureTime ?? v.aimedArrivalTime,
                  let aimed = iso.date(from: aimedRaw) else { return nil }
            // timetable-only visits get a blank Expected column rather than a false "On time"
            var etd: String? = nil
            if v.isRealTime == true,
               let expRaw = v.expectedDepartureTime ?? v.expectedArrivalTime,
               let expected = iso.date(from: expRaw) {
                etd = abs(expected.timeIntervalSince(aimed)) > 60 ? london.string(from: expected) : "On time"
            }
            return (aimed, Service(std: london.string(from: aimed), etd: etd, platform: nil,
                                   isCancelled: v.cancelled == true,
                                   destination: [.init(locationName: v.destinationName ?? "?")]))
        }
        .sorted { $0.0 < $1.0 }
        .prefix(20)
        .map(\.1)
}

private struct NETStops: Decodable {
    struct Embedded: Decodable {
        struct Stop: Decodable {
            let atcoCode: String
            let commonName: String
            let indicator: String?
        }
        let stops: [Stop]
        enum CodingKeys: String, CodingKey { case stops = "naptan:stop" }
    }
    let _embedded: Embedded
}

private var cachedNETStops: [Station]?

func netTramSearch(_ query: String) async throws -> [Station] {
    let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
    guard !trimmed.isEmpty else { return [] }
    if cachedNETStops == nil {
        let url = URL(string: "https://traveline.arcticapi.com/network/lines/NEXT:NETTRAM:TRAM/stops")!
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        cachedNETStops = try JSONDecoder().decode(NETStops.self, from: data)._embedded.stops.map { stop in
            let base = stop.commonName.replacingOccurrences(of: " Tram Stop", with: "")
            let name = stop.indicator.map { "\(base) (\($0))" } ?? base
            return Station(code: stop.atcoCode, name: name)
        }
    }
    return (cachedNETStops ?? []).filter { $0.name.lowercased().contains(trimmed) }
}
