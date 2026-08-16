import WidgetKit
import SwiftUI

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> BoardEntry {
        BoardEntry(date: .now, services: [], error: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (BoardEntry) -> Void) {
        Task { completion(await load()) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<BoardEntry>) -> Void) {
        Task {
            let base = await load()
            // one entry per minute boundary from a single fetch: clock ticks and departed
            // trains drop off on the minute; data itself refetches ~5 min (system budget)
            let cal = Calendar.current
            let nextMinute = cal.nextDate(after: .now, matching: DateComponents(second: 0),
                                          matchingPolicy: .nextTime) ?? .now.addingTimeInterval(60)
            var entries = [base]
            for i in 0..<6 {
                let date = nextMinute.addingTimeInterval(Double(i) * 60)
                entries.append(BoardEntry(date: date,
                                          services: base.services.filter { !departed($0, by: date) },
                                          error: base.error))
            }
            completion(Timeline(entries: entries, policy: .after(nextMinute.addingTimeInterval(300))))
        }
    }

    private func departed(_ s: Service, by date: Date) -> Bool {
        // effective departure: etd when it is a clock time, else scheduled std
        let time = (s.etd?.contains(":") == true ? s.etd : s.std) ?? ""
        let parts = time.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return false }
        let cal = Calendar.current
        guard var dep = cal.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: date) else { return false }
        // ponytail: times near midnight roll to tomorrow; assume nothing sits on the board >6h
        if dep < date.addingTimeInterval(-6 * 3600) { dep = cal.date(byAdding: .day, value: 1, to: dep) ?? dep }
        return dep < date
    }

    private func load() async -> BoardEntry {
        do {
            return BoardEntry(date: .now, services: try await fetchBoard(code: Station.selected.code), error: nil)
        } catch {
            return BoardEntry(date: .now, services: [], error: error.localizedDescription)
        }
    }
}

@main
struct TrainWidget: Widget {
    var body: some WidgetConfiguration {
        
        StaticConfiguration(kind: "TrainBoard", provider: Provider()) { entry in
            BoardView(entry: entry, station: Station.selected, rowLimit: 6)
                .containerBackground(.black, for: .widget)
        }
        .configurationDisplayName(String("Train Board"))
        .description(String("Live National Rail departures from your chosen station."))
        .supportedFamilies([.systemMedium])
    }
}

#Preview(as: .systemMedium) {
    TrainWidget()
} timeline: {
    BoardEntry(date: .now, services: [], error: nil)
}
