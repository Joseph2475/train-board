import WidgetKit
import SwiftUI

struct Station: Identifiable, Hashable {
    var code: String
    var name: String
    var id: String { code }

    static let fallback = Station(code: "PAD", name: "London Paddington")

    // app-group defaults shared between app and widget (Sequoia requires the team-ID prefix)
    static let sharedDefaults = UserDefaults(suiteName: "69TCYK37VK.com.josephmoylan.trainboard") ?? .standard

    static var selected: Station {
        get {
            guard let code = sharedDefaults.string(forKey: "stationCode"),
                  let name = sharedDefaults.string(forKey: "stationName") else { return .fallback }
            return Station(code: code, name: name)
        }
        set {
            sharedDefaults.set(newValue.code, forKey: "stationCode")
            sharedDefaults.set(newValue.name, forKey: "stationName")
        }
    }
}

// MARK: - Huxley2 API (JSON proxy for National Rail live departure boards)

struct Board: Decodable {
    let trainServices: [Service]?
}

struct Service: Decodable {
    struct Location: Decodable { let locationName: String }
    let std: String?
    let etd: String?
    let platform: String?
    let isCancelled: Bool
    let destination: [Location]

    var destinationName: String { destination.first?.locationName ?? "?" }
}

// MARK: - Networks

enum Network: String, CaseIterable {
    case ukRail = "UK Rail"
    case caltrain = "Caltrain"
    case swiss = "Switzerland"
    case germany = "Germany"
    case ireland = "Ireland"
    case portugal = "Portugal"
    case netTrams = "NET Trams"

    static var selected: Network {
        Network(rawValue: Station.sharedDefaults.string(forKey: "network") ?? "") ?? .ukRail
    }

    var timeZone: TimeZone {
        switch self {
        case .ukRail: TimeZone(identifier: "Europe/London")!
        case .caltrain: TimeZone(identifier: "America/Los_Angeles")!
        case .swiss: TimeZone(identifier: "Europe/Zurich")!
        case .germany: TimeZone(identifier: "Europe/Berlin")!
        case .ireland: TimeZone(identifier: "Europe/Dublin")!
        case .portugal: TimeZone(identifier: "Europe/Lisbon")!
        case .netTrams: TimeZone(identifier: "Europe/London")!
        }
    }

    var idPrefix: String {
        switch self {
        case .ukRail: "uk"; case .caltrain: "ct"; case .swiss: "ch"; case .germany: "de"; case .ireland: "ie"; case .portugal: "pt"; case .netTrams: "nt"
        }
    }

    static func from(prefix: String) -> Network {
        allCases.first { $0.idPrefix == prefix } ?? .ukRail
    }

    // ponytail: Germany's code stays wired up but unlisted until its API proves reliable
    static var active: [Network] { allCases.filter { $0 != .germany } }

    // ponytail: bundled key is fine at beta scale (511 caps keys at 60 req/hr, so ~4-5 users);
    // move behind a caching proxy before any wide release
    static var api511Key: String {
        let stored = Station.sharedDefaults.string(forKey: "api511Key") ?? ""
        return stored.isEmpty ? default511Key : stored
    }

    var fallbackStation: Station {
        switch self {
        case .ukRail: Station(code: "PAD", name: "London Paddington")
        case .caltrain: Station(code: "san_francisco", name: "San Francisco")
        case .swiss: Station(code: "8503000", name: "Zürich HB")
        case .germany: Station(code: "8011160", name: "Berlin Hbf")
        case .ireland: Station(code: "CNLLY", name: "Dublin Connolly")
        case .portugal: Station(code: "94-31039", name: "Lisboa Oriente")
        case .netTrams: Station(code: "9400ZZNOOMS1", name: "Old Market Square (NET04)")
        }
    }
}

// "HH:mm" in a network's local timezone; shared by the board view and all fetchers
func clock(for timeZone: TimeZone) -> DateFormatter {
    let f = DateFormatter()
    f.dateFormat = "HH:mm"
    f.timeZone = timeZone
    return f
}

func fetchBoard(network: Network = .selected, code: String) async throws -> [Service] {
    switch network {
    case .ukRail: try await ukBoard(code: code)
    case .caltrain: try await caltrainBoard(stop: code)
    case .swiss: try await swissBoard(code: code)
    case .germany: try await germanBoard(code: code)
    case .ireland: try await irishBoard(code: code)
    case .portugal: try await portugalBoard(code: code)
    case .netTrams: try await netTramBoard(code: code)
    }
}

func searchStations(network: Network = .selected, _ query: String) async throws -> [Station] {
    switch network {
    case .ukRail: try await ukSearch(query)
    case .caltrain: try await caltrainSearch(query)
    case .swiss: try await swissSearch(query)
    case .germany: try await germanSearch(query)
    case .ireland: try await irishSearch(query)
    case .portugal: try await portugalSearch(query)
    case .netTrams: try await netTramSearch(query)
    }
}

// MARK: - UK (Huxley2, keyless)

private func ukBoard(code: String) async throws -> [Service] {
    do { return try await trainiacBoard(code: code) }
    catch { return try await huxleyBoard(code: code) }
}

private func huxleyBoard(code: String) async throws -> [Service] {
    // ponytail: public Huxley2 demo instance is flaky (intermittent 500s), so retry
    let url = URL(string: "https://huxley2.azurewebsites.net/departures/\(code.lowercased())/20")!
    var lastError: Error = URLError(.unknown)
    for attempt in 1...2 {
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            return try JSONDecoder().decode(Board.self, from: data).trainServices ?? []
        } catch {
            lastError = error
            if attempt < 2 { try? await Task.sleep(for: .seconds(2)) }
        }
    }
    throw lastError
}

// Primary: traini.ac UK rail REST API (keyless, Darwin-backed). One GET, plain JSON.
private let londonClock: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm"
    f.timeZone = TimeZone(identifier: "Europe/London")
    return f
}()

private func trainiacBoard(code: String) async throws -> [Service] {
    struct DepartureList: Decodable {
        struct Departure: Decodable {
            struct Place: Decodable { let name: String }
            let departs: String
            let expected_departs: String?
            let platform: String?
            let destination: Place
            let status: String?
            let not_for_display: Bool?
            let train_id: String?
        }
        let results: [Departure]
    }

    guard let encoded = code.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
        throw URLError(.badURL)
    }
    let url = URL(string: "https://api.traini.ac/api/departures/\(encoded)?limit=20")!
    let (data, response) = try await URLSession.shared.data(from: url)
    // Non-2xx is a JSON error body (unknown station, database down): let the Huxley fallback run.
    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
    let iso = ISO8601DateFormatter()
    var seenTrains = Set<String>()
    return try JSONDecoder().decode(DepartureList.self, from: data).results
        .filter { $0.not_for_display != true && seenTrains.insert($0.train_id ?? UUID().uuidString).inserted }
        .compactMap { d -> (Date, Service)? in
            guard let departs = iso.date(from: d.departs) else { return nil }
            let cancelled = d.status?.lowercased().contains("cancel") == true
            var etd = "On time"
            if let expRaw = d.expected_departs, let expected = iso.date(from: expRaw),
               expected.timeIntervalSince(departs) > 60 {
                etd = londonClock.string(from: expected)
            }
            return (departs, Service(std: londonClock.string(from: departs), etd: etd,
                                     platform: d.platform, isCancelled: cancelled,
                                     destination: [.init(locationName: d.destination.name.capitalized)]))
        }
        .sorted { $0.0 < $1.0 }
        .map(\.1)
}

private struct CrsResult: Decodable {
    let stationName: String
    let crsCode: String
}

private func ukSearch(_ query: String) async throws -> [Station] {
    let trimmed = query.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty,
          let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
    else { return [] }
    let url = URL(string: "https://huxley2.azurewebsites.net/crs/\(encoded)")!
    let (data, response) = try await URLSession.shared.data(from: url)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
        throw URLError(.badServerResponse)
    }
    return try JSONDecoder().decode([CrsResult].self, from: data)
        .map { Station(code: $0.crsCode, name: $0.stationName) }
}

// MARK: - Caltrain (511.org, free API key required)

private let pacificClock: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm"
    f.timeZone = TimeZone(identifier: "America/Los_Angeles")
    return f
}()

private func data511(_ path: String, _ params: String) async throws -> Data {
    let key = Network.api511Key
    guard !key.isEmpty else {
        throw NSError(domain: "TrainBoard", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Add your free 511.org API key in the app"])
    }
    let url = URL(string: "https://api.511.org/transit/\(path)?api_key=\(key)&format=json&\(params)")!
    let (data, response) = try await URLSession.shared.data(from: url)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
    // 511 prefixes responses with a UTF-8 BOM that JSONDecoder rejects
    return data.starts(with: [0xEF, 0xBB, 0xBF]) ? data.dropFirst(3) : data
}

private struct StopsResponse: Decodable {
    struct Contents_: Decodable {
        struct DataObjects: Decodable {
            struct Stop: Decodable {
                struct Extensions_: Decodable { let ParentStation: String? }
                let id: String
                let Name: String
                let Extensions: Extensions_?
            }
            let ScheduledStopPoint: [Stop]
        }
        let dataObjects: DataObjects
    }
    let Contents: Contents_
}

private var cachedCaltrainStops: [Station]?

private func caltrainSearch(_ query: String) async throws -> [Station] {
    let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
    guard !trimmed.isEmpty else { return [] }
    if cachedCaltrainStops == nil {
        let data = try await data511("stops", "operator_id=CT")
        // one entry per parent station (directional platforms merge; board shows NB/SB in Plat)
        var seen = Set<String>()
        cachedCaltrainStops = try JSONDecoder().decode(StopsResponse.self, from: data)
            .Contents.dataObjects.ScheduledStopPoint
            .compactMap { stop -> Station? in
                guard let parent = stop.Extensions?.ParentStation, seen.insert(parent).inserted else { return nil }
                let name = stop.Name
                    .replacingOccurrences(of: " Caltrain Station", with: "")
                    .replacingOccurrences(of: " Northbound", with: "")
                    .replacingOccurrences(of: " Southbound", with: "")
                return Station(code: parent, name: name)
            }
    }
    return (cachedCaltrainStops ?? []).filter { $0.name.lowercased().contains(trimmed) }
}

private struct SiriResponse: Decodable {
    struct Delivery: Decodable {
        struct StopDelivery: Decodable {
            struct Visit: Decodable { let MonitoredVehicleJourney: Journey }
            let MonitoredStopVisit: [Visit]?
        }
        let StopMonitoringDelivery: StopDelivery?
    }
    let ServiceDelivery: Delivery
}

private struct Journey: Decodable {
    struct Call: Decodable {
        let AimedDepartureTime: String?
        let ExpectedDepartureTime: String?
        let AimedArrivalTime: String?
        let ExpectedArrivalTime: String?
    }
    let DestinationName: String?
    let MonitoredCall: Call?
}

// caltrain.com's own keyless predictions endpoint (same Swiftly feed their site board uses).
// Predicted times only, no schedule join; 511 SIRI below stays as fallback.
private struct CaltrainPredictions: Decodable {
    struct StopData: Decodable {
        let predictions: [Prediction]?
    }
    struct Prediction: Decodable {
        let tripUpdate: TripUpdate
        enum CodingKeys: String, CodingKey { case tripUpdate = "TripUpdate" }
    }
    struct TripUpdate: Decodable {
        struct TripInfo: Decodable {
            let directionId: Int?
            enum CodingKeys: String, CodingKey { case directionId = "DirectionId" }
        }
        struct StopTime: Decodable {
            struct Event: Decodable {
                let time: Int?
                enum CodingKeys: String, CodingKey { case time = "Time" }
            }
            let departure: Event?
            let arrival: Event?
            enum CodingKeys: String, CodingKey { case departure = "Departure", arrival = "Arrival" }
        }
        let trip: TripInfo
        let stopTimeUpdate: [StopTime]?
        enum CodingKeys: String, CodingKey { case trip = "Trip", stopTimeUpdate = "StopTimeUpdate" }
    }
    let data: [StopData]?
}

private func caltrainWebBoard(stop: String) async throws -> [Service] {
    let url = URL(string: "https://www.caltrain.com/gtfs/stops/\(stop)/predictions")!
    let (data, response) = try await URLSession.shared.data(from: url)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
    let predictions = try JSONDecoder().decode(CaltrainPredictions.self, from: data)
        .data?.flatMap { $0.predictions ?? [] } ?? []
    return predictions
        .compactMap { p -> (Date, Service)? in
            guard let stopTime = p.tripUpdate.stopTimeUpdate?.first,
                  let epoch = stopTime.departure?.time ?? stopTime.arrival?.time else { return nil }
            let date = Date(timeIntervalSince1970: TimeInterval(epoch))
            guard date > .now.addingTimeInterval(-60) else { return nil }
            // Caltrain GTFS: direction 0 = northbound, 1 = southbound
            let northbound = p.tripUpdate.trip.directionId == 0
            return (date, Service(std: pacificClock.string(from: date), etd: nil,
                                  platform: northbound ? "N" : "S",
                                  isCancelled: false,
                                  destination: [.init(locationName: northbound ? "San Francisco" : "San Jose")]))
        }
        .sorted { $0.0 < $1.0 }
        .map(\.1)
}

private func caltrainBoard(stop: String) async throws -> [Service] {
    do { return try await caltrainWebBoard(stop: stop) }
    catch {
        // 511 fallback only understands numeric GTFS stop codes, not parent station slugs
        guard stop.allSatisfy(\.isNumber) else { throw error }
        return try await caltrain511Board(stop: stop)
    }
}

private func caltrain511Board(stop: String) async throws -> [Service] {
    let data = try await data511("StopMonitoring", "agency=CT&stopcode=\(stop)")
    let visits = try JSONDecoder().decode(SiriResponse.self, from: data)
        .ServiceDelivery.StopMonitoringDelivery?.MonitoredStopVisit ?? []
    let iso = ISO8601DateFormatter()
    return visits.compactMap { visit -> Service? in
        let j = visit.MonitoredVehicleJourney
        guard let call = j.MonitoredCall,
              let aimedRaw = call.AimedDepartureTime ?? call.AimedArrivalTime,
              let aimed = iso.date(from: aimedRaw) else { return nil }
        var etd = "On time"
        if let expRaw = call.ExpectedDepartureTime ?? call.ExpectedArrivalTime,
           let expected = iso.date(from: expRaw), expected.timeIntervalSince(aimed) > 90 {
            etd = pacificClock.string(from: expected)
        }
        return Service(std: pacificClock.string(from: aimed), etd: etd, platform: nil,
                       isCancelled: false,
                       destination: [.init(locationName: (j.DestinationName ?? "?").replacingOccurrences(of: " Caltrain Station", with: ""))])
    }
    .sorted { ($0.std ?? "") < ($1.std ?? "") }
}

// MARK: - Entry + View

struct BoardEntry: TimelineEntry {
    let date: Date
    let services: [Service]
    let error: String?
    var station: Station = .fallback
    var network: Network = .ukRail
}

struct BoardView: View {
    var entry: BoardEntry
    var station: Station
    var network: Network = .ukRail
    var rowLimit: Int = 8
    var compact: Bool = false
    var onStationTap: (() -> Void)? = nil

    private let amber = Color.orange

    private var services: [Service] { Array(entry.services.prefix(rowLimit)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            Divider().overlay(amber.opacity(0.4))
            if entry.error != nil {
                message("No trains available right now")
            } else if entry.services.isEmpty {
                message("No trains due")
            } else {
                grid
            }
        }
    }

    private var header: some View {
        HStack {
            if let onStationTap {
                Button(action: onStationTap) {
                    HStack(spacing: 3) {
                        Text(station.name.uppercased())
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                    }
                }
                .buttonStyle(.plain)
            } else {
                Text(station.name.uppercased())
            }
            Spacer()
            Text(clock(for: network.timeZone).string(from: entry.date))
                .foregroundStyle(amber.opacity(0.6))
        }
        .font(.system(.caption, design: .monospaced).bold())
        .foregroundStyle(amber)
    }

    private var grid: some View {
        HStack(alignment: .top, spacing: 0) {
            column("Time", width: 44, center: false) { s in
                // compact: no Expected column, so the time itself carries the status colour
                Text(s.std ?? "--:--").foregroundStyle(compact ? statusColor(s) : amber)
            }
            columnDivider
            column("Destination", width: nil, center: false) { s in
                Text(s.destinationName).truncationMode(.tail).foregroundStyle(amber)
            }
            if !compact {
                columnDivider
                column("Plat", width: 36, center: true) { s in
                    Text(s.platform ?? "-").foregroundStyle(amber.opacity(0.6))
                }
                columnDivider
                column("Expected", width: 72, center: false) { s in
                    Text(statusText(s)).foregroundStyle(statusColor(s))
                }
            }
        }
    }

    private var columnDivider: some View {
        Rectangle().fill(amber.opacity(0.25)).frame(width: 1)
    }

    private func column<Cell: View>(
        _ title: String, width: CGFloat?, center: Bool,
        @ViewBuilder cell: @escaping (Service) -> Cell
    ) -> some View {
        let alignment: Alignment = center ? .center : .leading
        return VStack(spacing: 0) {
            Text(title.uppercased())
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(amber.opacity(0.5))
                .padding(.vertical, 1.5)
                .padding(.horizontal, 3)
                .frame(maxWidth: .infinity, alignment: alignment)
            Rectangle().fill(amber.opacity(0.25)).frame(height: 1)
            ForEach(Array(services.enumerated()), id: \.offset) { i, s in
                cell(s)
                    .font(.system(size: 10, design: .monospaced))
                    .lineLimit(1)
                    .padding(.vertical, 1.5)
                    .padding(.horizontal, 3)
                    .frame(maxWidth: .infinity, alignment: alignment)
                    .background(i % 2 == 1 ? Color.white.opacity(0.03) : .clear)
            }
        }
        .frame(width: width)
    }

    private func message(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(amber.opacity(0.7))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
            Spacer()
        }
    }

    private func statusText(_ s: Service) -> String {
        if s.isCancelled { return "Cancelled" }
        return s.etd ?? ""
    }

    private func statusColor(_ s: Service) -> Color {
        if s.isCancelled { return .red }
        if s.etd == "On time" { return .green }
        return .yellow
    }
}
