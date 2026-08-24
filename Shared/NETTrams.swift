import Foundation

// Nottingham Express Transit trams via Traveline's Passenger API (keyless HAL JSON).
// NET stopped publishing vehicle tracking, so visits are timetable-derived today;
// the real-time fields are decoded anyway and light up if NET ever resumes.
// Stops are merged like Caltrain: one station per stop, both platforms on one board.

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

private struct NETPlatform {
    let atco: String
    let indicator: String
}

// every NET platform; station codes are the ATCO minus its trailing platform digit
private var cachedNETPlatforms: [NETPlatform]?
private var cachedNETStops: [Station]?

private func loadNETStops() async throws {
    guard cachedNETPlatforms == nil else { return }
    let url = URL(string: "https://traveline.arcticapi.com/network/lines/NEXT:NETTRAM:TRAM/stops")!
    let (data, response) = try await URLSession.shared.data(from: url)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
    let stops = try JSONDecoder().decode(NETStops.self, from: data)._embedded.stops
    cachedNETPlatforms = stops.map {
        NETPlatform(atco: $0.atcoCode, indicator: ($0.indicator ?? "").replacingOccurrences(of: "NET", with: ""))
    }
    var seen = Set<String>()
    cachedNETStops = stops.compactMap { stop in
        let base = String(stop.atcoCode.dropLast())
        guard seen.insert(base).inserted else { return nil }
        return Station(code: base, name: stop.commonName.replacingOccurrences(of: " Tram Stop", with: ""))
    }
}

// NET is one north-south line through the city: label trams by which end they're heading to
private func netDirection(to destination: String?) -> String? {
    let d = (destination ?? "").lowercased()
    if d.contains("hucknall") || d.contains("phoenix") { return "N" }
    if d.contains("toton") || d.contains("clifton") { return "S" }
    return nil
}

func netTramBoard(code: String) async throws -> [Service] {
    try await loadNETStops()
    let platforms = (cachedNETPlatforms ?? []).filter { $0.atco.hasPrefix(code) }
    let iso = ISO8601DateFormatter()
    let london = clock(for: Network.netTrams.timeZone)

    let boards = await withTaskGroup(of: [(Date, Service)].self) { group in
        for platform in platforms {
            group.addTask {
                let url = URL(string: "https://traveline.arcticapi.com/network/stops/\(platform.atco)/visits")!
                guard let (data, response) = try? await URLSession.shared.data(from: url),
                      (response as? HTTPURLResponse)?.statusCode == 200,
                      let visits = try? JSONDecoder().decode(NETVisits.self, from: data)._embedded.visits
                else { return [] }
                return visits.compactMap { v -> (Date, Service)? in
                    guard let aimedRaw = v.aimedDepartureTime ?? v.aimedArrivalTime,
                          let aimed = iso.date(from: aimedRaw) else { return nil }
                    // timetable-only visits get a blank Expected column rather than a false "On time"
                    var etd: String? = nil
                    if v.isRealTime == true,
                       let expRaw = v.expectedDepartureTime ?? v.expectedArrivalTime,
                       let expected = iso.date(from: expRaw) {
                        etd = abs(expected.timeIntervalSince(aimed)) > 60 ? london.string(from: expected) : "On time"
                    }
                    return (aimed, Service(std: london.string(from: aimed), etd: etd,
                                           platform: netDirection(to: v.destinationName) ?? platform.indicator,
                                           isCancelled: v.cancelled == true,
                                           destination: [.init(locationName: v.destinationName ?? "?")]))
                }
            }
        }
        return await group.reduce(into: []) { $0 += $1 }
    }
    return boards.sorted { $0.0 < $1.0 }.prefix(20).map(\.1)
}

func netTramSearch(_ query: String) async throws -> [Station] {
    let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
    guard !trimmed.isEmpty else { return [] }
    try await loadNETStops()
    return (cachedNETStops ?? []).filter { $0.name.lowercased().contains(trimmed) }
}
