import Foundation

// MARK: - Ireland (Irish Rail, keyless XML API)

private let irishBase = "https://api.irishrail.ie/realtime/realtime.asmx"

// Flat XML rows like <objStationData><Schdepart>10:33</Schdepart>...</objStationData>
// collected as [tag: text] dictionaries; values are trimmed (this API pads them).
private final class IrishRows: NSObject, XMLParserDelegate {
    let rowElement: String
    var rows: [[String: String]] = []
    private var current: [String: String]?
    private var text = ""

    init(rowElement: String) { self.rowElement = rowElement }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        if name == rowElement { current = [:] }
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
                qualifiedName: String?) {
        if name == rowElement {
            rows.append(current ?? [:])
            current = nil
        } else if current != nil {
            current?[name] = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

private func irishRows(_ path: String, row: String) async throws -> [[String: String]] {
    let url = URL(string: "\(irishBase)/\(path)")!
    let (data, response) = try await URLSession.shared.data(from: url)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
    let collector = IrishRows(rowElement: row)
    let parser = XMLParser(data: data)
    parser.delegate = collector
    guard parser.parse() else { throw URLError(.cannotParseResponse) }
    return collector.rows
}

func irishBoard(code: String) async throws -> [Service] {
    guard let encoded = code.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
        throw URLError(.badURL)
    }
    return try await irishRows("getStationDataByCodeXML?StationCode=\(encoded)", row: "objStationData")
        .compactMap { row -> Service? in
            let std = row["Schdepart"] ?? ""
            // terminating trains (Locationtype D) do not depart; 00:00 marks no departure time
            guard row["Locationtype"] != "D", !std.isEmpty, std != "00:00" else { return nil }
            let late = Int(row["Late"] ?? "") ?? 0
            var etd = "On time"
            if late > 0 {
                let expected = row["Expdepart"] ?? ""
                etd = expected.isEmpty || expected == "00:00" ? "Delayed" : expected
            }
            // ponytail: the feed has no cancellation flag; cancelled trains just drop out of it
            return Service(std: std, etd: etd, platform: nil, isCancelled: false,
                           destination: [.init(locationName: row["Destination"] ?? "?")])
        }
        // ponytail: string sort wraps at midnight; the feed only spans ~90 min so at most the last rows misorder
        .sorted { ($0.std ?? "") < ($1.std ?? "") }
}

private var cachedIrishStations: [Station]?

func irishSearch(_ query: String) async throws -> [Station] {
    let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
    guard !trimmed.isEmpty else { return [] }
    if cachedIrishStations == nil {
        cachedIrishStations = try await irishRows("getAllStationsXML", row: "objStation")
            .compactMap { row in
                guard let code = row["StationCode"], let name = row["StationDesc"],
                      !code.isEmpty, !name.isEmpty else { return nil }
                return Station(code: code, name: name)
            }
    }
    return (cachedIrishStations ?? []).filter { $0.name.lowercased().contains(trimmed) }
}
