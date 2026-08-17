import WidgetKit
import SwiftUI
import AppIntents

// MARK: - Per-widget station configuration

struct StationEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Station"
    static let defaultQuery = StationQuery()

    // id carries everything so no lookup is needed to resolve: "uk|PAD|London Paddington"
    let id: String

    var parsed: (network: Network, station: Station) {
        let parts = id.split(separator: "|", maxSplits: 2).map(String.init)
        let network = Network.from(prefix: parts.first ?? "uk")
        guard parts.count == 3 else { return (network, network.fallbackStation) }
        return (network, Station(code: parts[1], name: parts[2]))
    }

    var displayRepresentation: DisplayRepresentation {
        let (network, station) = parsed
        return DisplayRepresentation(title: "\(station.name) (\(network.rawValue))")
    }

    static func make(_ network: Network, _ station: Station) -> StationEntity {
        StationEntity(id: "\(network.idPrefix)|\(station.code)|\(station.name)")
    }
}

struct StationQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [StationEntity] {
        identifiers.map(StationEntity.init(id:))
    }

    // networks that timed out get benched briefly so the next keystroke's search is instant
    nonisolated(unsafe) static var deadUntil: [String: Date] = [:]

    func entities(matching string: String) async throws -> [StationEntity] {
        let live = Network.allCases.filter { (Self.deadUntil[$0.idPrefix] ?? .distantPast) < .now }
        return await withTaskGroup(of: [StationEntity]?.self) { group in
            for network in live {
                group.addTask {
                    // race each network against a short deadline; a hung API loses fast
                    await withTaskGroup(of: [StationEntity]?.self) { race in
                        race.addTask {
                            ((try? await searchStations(network: network, string)) ?? []).map { .make(network, $0) }
                        }
                        race.addTask {
                            try? await Task.sleep(for: .seconds(1.5))
                            return nil
                        }
                        let first = await race.next() ?? nil
                        race.cancelAll()
                        if first == nil { Self.deadUntil[network.idPrefix] = .now.addingTimeInterval(120) }
                        return first
                    }
                }
            }
            return await group.reduce(into: []) { $0 += ($1 ?? []) }
        }
    }

    func suggestedEntities() async throws -> [StationEntity] {
        [.make(Network.selected, Station.selected),
         .make(.caltrain, Network.caltrain.fallbackStation)]
    }
}

struct StationConfigIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Station"
    static let description = IntentDescription("Choose which station this widget shows.")

    @Parameter(title: "Station")
    var station: StationEntity?
}

// MARK: - Timeline

struct Provider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> BoardEntry {
        BoardEntry(date: .now, services: [], error: nil)
    }

    func snapshot(for configuration: StationConfigIntent, in context: Context) async -> BoardEntry {
        await load(configuration)
    }

    func timeline(for configuration: StationConfigIntent, in context: Context) async -> Timeline<BoardEntry> {
        let base = await load(configuration)
        // one entry per minute boundary from a single fetch: clock ticks and departed
        // trains drop off on the minute; data itself refetches ~5 min (system budget)
        let cal = Calendar.current
        let nextMinute = cal.nextDate(after: .now, matching: DateComponents(second: 0),
                                      matchingPolicy: .nextTime) ?? .now.addingTimeInterval(60)
        var entries = [base]
        for i in 0..<6 {
            let date = nextMinute.addingTimeInterval(Double(i) * 60)
            entries.append(BoardEntry(date: date,
                                      services: base.services.filter { !departed($0, by: date, network: base.network) },
                                      error: base.error,
                                      station: base.station,
                                      network: base.network))
        }
        return Timeline(entries: entries, policy: .after(nextMinute.addingTimeInterval(300)))
    }

    private func load(_ configuration: StationConfigIntent) async -> BoardEntry {
        // unconfigured widget follows the app's chosen station
        let (network, station) = configuration.station?.parsed ?? (Network.selected, Station.selected)
        do {
            return BoardEntry(date: .now, services: try await fetchBoard(network: network, code: station.code),
                              error: nil, station: station, network: network)
        } catch {
            return BoardEntry(date: .now, services: [], error: error.localizedDescription,
                              station: station, network: network)
        }
    }

    private func departed(_ s: Service, by date: Date, network: Network) -> Bool {
        // effective departure: etd when it is a clock time, else scheduled std;
        // board times are in the network's timezone, so compare in that calendar
        let time = (s.etd?.contains(":") == true ? s.etd : s.std) ?? ""
        let parts = time.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return false }
        var cal = Calendar.current
        cal.timeZone = network.timeZone
        guard var dep = cal.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: date) else { return false }
        // ponytail: times near midnight roll to tomorrow; assume nothing sits on the board >6h
        if dep < date.addingTimeInterval(-6 * 3600) { dep = cal.date(byAdding: .day, value: 1, to: dep) ?? dep }
        return dep < date
    }
}

// MARK: - Widget

struct WidgetBoard: View {
    var entry: BoardEntry
    @Environment(\.widgetFamily) var family

    var body: some View {
        BoardView(entry: entry, station: entry.station, network: entry.network,
                  rowLimit: family == .systemLarge ? 18 : (family == .systemSmall ? 5 : 6),
                  compact: family == .systemSmall)
            .containerBackground(.black, for: .widget)
    }
}

@main
struct TrainWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "TrainBoard", intent: StationConfigIntent.self, provider: Provider()) { entry in
            WidgetBoard(entry: entry)
        }
        .configurationDisplayName(String("Train Board"))
        .description(String("Live departures for a station of your choice."))
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
