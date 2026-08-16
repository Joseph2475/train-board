import WidgetKit
import SwiftUI

struct Station: Identifiable, Hashable {
    var code: String
    var name: String
    var id: String { code }

    static let fallback = Station(code: "STD", name: "Stroud")

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

    static var selected: Network {
        Network(rawValue: Station.sharedDefaults.string(forKey: "network") ?? "") ?? .ukRail
    }

    // ponytail: bundled key is fine at beta scale (511 caps keys at 60 req/hr, so ~4-5 users);
    // move behind a caching proxy before any wide release
    static var api511Key: String {
        let stored = Station.sharedDefaults.string(forKey: "api511Key") ?? ""
        return stored.isEmpty ? default511Key : stored
    }

    var fallbackStation: Station {
        switch self {
        case .ukRail: Station(code: "STD", name: "Stroud")
        case .caltrain: Station(code: "70012", name: "San Francisco")
        }
    }
}

func fetchBoard(code: String) async throws -> [Service] {
    switch Network.selected {
    case .ukRail: try await ukBoard(code: code)
    case .caltrain: try await caltrainBoard(stop: code)
    }
}

func searchStations(_ query: String) async throws -> [Station] {
    switch Network.selected {
    case .ukRail: try await ukSearch(query)
    case .caltrain: try await caltrainSearch(query)
    }
}

// MARK: - UK (Huxley2, keyless)

private func ukBoard(code: String) async throws -> [Service] {
    // ponytail: public Huxley2 demo instance is flaky (intermittent 500s), so retry
    let url = URL(string: "https://huxley2.azurewebsites.net/departures/\(code.lowercased())/10")!
    var lastError: Error = URLError(.unknown)
    for attempt in 1...3 {
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            return try JSONDecoder().decode(Board.self, from: data).trainServices ?? []
        } catch {
            lastError = error
            if attempt < 3 { try? await Task.sleep(for: .seconds(2)) }
        }
    }
    throw lastError
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
            struct Stop: Decodable { let id: String; let Name: String }
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
        cachedCaltrainStops = try JSONDecoder().decode(StopsResponse.self, from: data)
            .Contents.dataObjects.ScheduledStopPoint
            .map { Station(code: $0.id, name: $0.Name.replacingOccurrences(of: " Caltrain Station", with: "")) }
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
            let destination = p.tripUpdate.trip.directionId == 0 ? "San Francisco" : "San Jose"
            return (date, Service(std: pacificClock.string(from: date), etd: nil, platform: nil,
                                  isCancelled: false,
                                  destination: [.init(locationName: destination)]))
        }
        .sorted { $0.0 < $1.0 }
        .map(\.1)
}

private func caltrainBoard(stop: String) async throws -> [Service] {
    do { return try await caltrainWebBoard(stop: stop) }
    catch { return try await caltrain511Board(stop: stop) }
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
}

struct BoardView: View {
    var entry: BoardEntry
    var station: Station
    var rowLimit: Int = 8
    var onStationTap: (() -> Void)? = nil

    private let amber = Color.orange

    private var services: [Service] { Array(entry.services.prefix(rowLimit)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            Divider().overlay(amber.opacity(0.4))
            if let error = entry.error {
                message("No data: \(error)")
            } else if entry.services.isEmpty {
                message("No departures")
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
            Text(entry.date, style: .time)
                .foregroundStyle(amber.opacity(0.6))
        }
        .font(.system(.caption, design: .monospaced).bold())
        .foregroundStyle(amber)
    }

    private var grid: some View {
        HStack(alignment: .top, spacing: 0) {
            column("Time", width: 44, center: false) { s in
                Text(s.std ?? "--:--").foregroundStyle(amber)
            }
            columnDivider
            column("Destination", width: nil, center: false) { s in
                Text(s.destinationName).truncationMode(.tail).foregroundStyle(amber)
            }
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
