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

func fetchBoard(code: String) async throws -> [Service] {
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

func searchStations(_ query: String) async throws -> [Station] {
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
