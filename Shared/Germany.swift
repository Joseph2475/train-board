import Foundation

// Germany: keyless community transport.rest API (hafas, Deutsche Bahn data).
// v6.db.transport.rest; community-hosted, so reliability is Huxley-grade.

private let railProducts: Set<String> = ["nationalExpress", "national", "regionalExpress", "regional", "suburban"]

func germanBoard(code: String) async throws -> [Service] {
    struct DepartureList: Decodable {
        struct Departure: Decodable {
            struct Line: Decodable { let product: String? }
            let when: String?          // expected (realtime); null when cancelled
            let plannedWhen: String?   // scheduled
            let delay: Int?            // seconds, null when no realtime data
            let platform: String?
            let plannedPlatform: String?
            let direction: String?
            let cancelled: Bool?
            let line: Line?
        }
        let departures: [Departure]
    }

    guard let encoded = code.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
        throw URLError(.badURL)
    }
    let url = URL(string: "https://v6.db.transport.rest/stops/\(encoded)/departures?duration=180&results=20")!
    let (data, response) = try await URLSession.shared.data(from: url)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
    let iso = ISO8601DateFormatter()
    let berlin = clock(for: Network.germany.timeZone)
    return try JSONDecoder().decode(DepartureList.self, from: data).departures
        .compactMap { d -> (Date, Service)? in
            // ponytail: unknown products kept; only drop known non-rail (bus/tram/ferry/subway)
            if let product = d.line?.product, !railProducts.contains(product) { return nil }
            guard let plannedRaw = d.plannedWhen ?? d.when, let planned = iso.date(from: plannedRaw) else { return nil }
            let cancelled = d.cancelled == true
            var etd: String? = "On time"
            if cancelled {
                etd = nil
            } else if d.delay ?? 0 >= 60, let expRaw = d.when, let expected = iso.date(from: expRaw) {
                etd = berlin.string(from: expected)
            }
            return (planned, Service(std: berlin.string(from: planned), etd: etd,
                                     platform: d.platform ?? d.plannedPlatform, isCancelled: cancelled,
                                     destination: [.init(locationName: d.direction ?? "?")]))
        }
        .sorted { $0.0 < $1.0 }
        .map(\.1)
}

func germanSearch(_ query: String) async throws -> [Station] {
    struct Location: Decodable {
        let type: String?
        let id: String?
        let name: String?
    }

    let trimmed = query.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty,
          let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
    else { return [] }
    let url = URL(string: "https://v6.db.transport.rest/locations?query=\(encoded)&results=10&stops=true&addresses=false&poi=false")!
    let (data, response) = try await URLSession.shared.data(from: url)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
    return try JSONDecoder().decode([Location].self, from: data)
        .compactMap { loc in
            guard loc.type == "stop" || loc.type == "station",
                  let id = loc.id, let name = loc.name else { return nil }
            return Station(code: id, name: name)
        }
}
