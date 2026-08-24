import Foundation

// Portugal: CP's own travel-api (backend of cp.pt "Next trains").
// Auth headers are published by CP in the public /fe-config.json, so fetch them at
// runtime instead of hardcoding; cache per-process and invalidate on 401.

private struct CPConfig: Decodable {
    let travelApiUrl: String
    let xcck: String
    let xccs: String
}

private var cachedCPConfig: CPConfig?

private func cpData(_ path: String) async throws -> Data {
    if cachedCPConfig == nil {
        let (data, _) = try await URLSession.shared.data(from: URL(string: "https://www.cp.pt/fe-config.json")!)
        cachedCPConfig = try JSONDecoder().decode(CPConfig.self, from: data)
    }
    guard let config = cachedCPConfig, let url = URL(string: config.travelApiUrl + path) else {
        throw URLError(.badURL)
    }
    var request = URLRequest(url: url)
    request.setValue(config.xcck, forHTTPHeaderField: "x-cp-connect-id")
    request.setValue(config.xccs, forHTTPHeaderField: "x-cp-connect-secret")
    let (data, response) = try await URLSession.shared.data(for: request)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
        cachedCPConfig = nil // keys rotated: refetch config on next refresh
        throw URLError(.badServerResponse)
    }
    return data
}

private struct CPTimetable: Decodable {
    struct Stop: Decodable {
        struct Named: Decodable { let designation: String }
        let trainDestination: Named
        let departureTime: String?
        let platform: String?
        let delay: Int?
        let ETD: String?
        let supression: String?
    }
    let stationStops: [Stop]
}

func portugalBoard(code: String) async throws -> [Service] {
    let lisbon = clock(for: Network.portugal.timeZone)
    let day = DateFormatter()
    day.dateFormat = "yyyy-MM-dd"
    day.timeZone = Network.portugal.timeZone
    let now = Date()
    let data = try await cpData("/stations/\(code)/timetable/\(day.string(from: now))?view=DEPARTURES&start=\(lisbon.string(from: now))")
    return try JSONDecoder().decode(CPTimetable.self, from: data).stationStops
        .compactMap { stop -> Service? in
            guard let departs = stop.departureTime else { return nil }
            var etd = "On time"
            if let delay = stop.delay, delay > 0, let expected = stop.ETD { etd = expected }
            return Service(std: departs, etd: etd,
                           platform: stop.platform,
                           isCancelled: stop.supression != nil,
                           destination: [.init(locationName: stop.trainDestination.designation)])
        }
        .sorted { ($0.std ?? "") < ($1.std ?? "") }
}

private struct CPStation: Decodable {
    let code: String
    let designation: String
}

private var cachedCPStations: [Station]?

func portugalSearch(_ query: String) async throws -> [Station] {
    let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
    guard !trimmed.isEmpty else { return [] }
    if cachedCPStations == nil {
        cachedCPStations = try JSONDecoder().decode([CPStation].self, from: await cpData("/stations"))
            .map { Station(code: $0.code, name: $0.designation) }
    }
    return (cachedCPStations ?? []).filter { $0.name.lowercased().contains(trimmed) }
}
