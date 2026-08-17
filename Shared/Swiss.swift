import Foundation

// Switzerland: transport.opendata.ch (keyless, official Swiss open transport data)

private struct SwissBoard: Decodable {
    struct Item: Decodable {
        struct Stop: Decodable {
            let departure: String?
            let delay: Int?
            let platform: String?
        }
        let stop: Stop
        let to: String
    }
    let stationboard: [Item]
}

func swissBoard(code: String) async throws -> [Service] {
    let url = URL(string: "https://transport.opendata.ch/v1/stationboard?id=\(code)&limit=20")!
    let (data, response) = try await URLSession.shared.data(from: url)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
    let iso = ISO8601DateFormatter()
    let zurich = clock(for: Network.swiss.timeZone)
    return try JSONDecoder().decode(SwissBoard.self, from: data).stationboard
        .compactMap { item -> (Date, Service)? in
            guard let raw = item.stop.departure, let departs = iso.date(from: raw) else { return nil }
            var etd = "On time"
            if let delay = item.stop.delay, delay > 0 {
                etd = zurich.string(from: departs.addingTimeInterval(Double(delay) * 60))
            }
            return (departs, Service(std: zurich.string(from: departs), etd: etd,
                                     platform: item.stop.platform, isCancelled: false,
                                     destination: [.init(locationName: item.to)]))
        }
        .sorted { $0.0 < $1.0 }
        .map(\.1)
}

private struct SwissLocations: Decodable {
    struct Loc: Decodable {
        let id: String?
        let name: String?
    }
    let stations: [Loc]
}

func swissSearch(_ query: String) async throws -> [Station] {
    let trimmed = query.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty,
          let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
    else { return [] }
    let url = URL(string: "https://transport.opendata.ch/v1/locations?query=\(encoded)&type=station")!
    let (data, response) = try await URLSession.shared.data(from: url)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
    return try JSONDecoder().decode(SwissLocations.self, from: data).stations
        .compactMap { loc -> Station? in
            guard let id = loc.id, let name = loc.name else { return nil }
            return Station(code: id, name: name)
        }
        .prefix(12)
        .map { $0 }
}
