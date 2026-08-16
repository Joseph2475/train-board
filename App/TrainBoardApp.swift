import SwiftUI
import WidgetKit

// swap in the real handle
let twitterURL = URL(string: "https://x.com/joseph_moylan2")!
let twitterLabel = "@joseph_moylan2"

@main
struct TrainBoardApp: App {
    var body: some Scene {
        WindowGroup {
            SettingsPage()
        }
        .windowResizability(.contentSize)
    }
}

struct SettingsPage: View {
    @AppStorage("stationCode", store: Station.sharedDefaults) var stationCode = Station.fallback.code
    @AppStorage("stationName", store: Station.sharedDefaults) var stationName = Station.fallback.name
    @AppStorage("network", store: Station.sharedDefaults) var networkRaw = Network.ukRail.rawValue
    @AppStorage("api511Key", store: Station.sharedDefaults) var api511Key = ""
    @State private var searchText = ""
    @State private var results: [Station] = []
    @State private var pending: Station?

    var body: some View {
        VStack(spacing: 14) {
            Text("🚆 Train Board").font(.title2.bold())

            Picker("Network", selection: $networkRaw) {
                ForEach(Network.allCases, id: \.rawValue) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: networkRaw) {
                let fallback = Network.selected.fallbackStation
                stationCode = fallback.code
                stationName = fallback.name
                searchText = ""
                results = []
                pending = nil
                WidgetCenter.shared.reloadAllTimelines()
            }

            if Network.selected == .caltrain {
                TextField("511.org API key", text: $api511Key)
                    .textFieldStyle(.roundedBorder)
                Link("Get a free key at 511.org", destination: URL(string: "https://511.org/open-data/token")!)
                    .font(.caption)
            }

            Text("The widget shows live departures for")
                .foregroundStyle(.secondary)
            Text(stationName)
                .font(.system(.title3, design: .monospaced).bold())
                .foregroundStyle(.orange)

            VStack(spacing: 0) {
                TextField("Search UK stations…", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                if !results.isEmpty {
                    List(results) { station in
                        Button {
                            pending = station
                        } label: {
                            HStack {
                                Text(station.name)
                                Spacer()
                                Text(station.code)
                                    .foregroundStyle(.secondary)
                                    .font(.system(.caption, design: .monospaced))
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(pending == station ? Color.accentColor.opacity(0.2) : nil)
                    }
                    .listStyle(.plain)
                    .frame(height: 140)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
                }
            }

            Button {
                guard let pending else { return }
                stationCode = pending.code
                stationName = pending.name
                searchText = ""
                results = []
                self.pending = nil
                WidgetCenter.shared.reloadAllTimelines()
            } label: {
                Text(pending.map { "Show departures from \($0.name)" } ?? "Choose a station")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(pending == nil)

            Link("Made by \(twitterLabel)", destination: twitterURL)
                .font(.caption)
        }
        .padding(24)
        .frame(width: 340)
        .task(id: searchText) {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, !searchText.isEmpty else { results = []; return }
            results = (try? await searchStations(searchText)) ?? []
        }
    }
}
