import Foundation

public enum KMLRoute {
    private static let maxXML = 20 * 1024 * 1024
    public static let defaultPace = 7 * 60 + 29

    public static func load(_ url: URL) throws -> TrackRoute {
        let archived = url.pathExtension.lowercased() == "kmz"
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= (archived ? 10 * 1024 * 1024 : maxXML) else {
            throw TrackError("轨迹文件超过大小上限。")
        }

        let data: Data
        if archived {
            data = try ZipReader.extractPrimaryKML(from: url, maxArchiveBytes: 10 * 1024 * 1024,
                                                   maxEntryBytes: maxXML)
        } else {
            data = try Data(contentsOf: url)
        }

        let reader = KMLReader()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = reader
        let parsed = parser.parse()
        if let error = reader.error { throw error }
        guard parsed else { throw TrackError("无法读取 KML XML。") }
        let segments = reader.segments
        guard segments.reduce(0, { $0 + $1.count }) >= 2 else {
            throw TrackError("KML 至少需要两个 LineString 或 gx:Track 轨迹点。")
        }
        let raw = segments.map { $0.map(\.point) }
        var route = TrackRoute(name: url.lastPathComponent, points: [], segmentStarts: [], timingIssue: nil)
        if segments.joined().contains(where: { $0.time == nil }) {
            route.untimedSegments = raw
            return withPace(route, secondsPerKilometer: defaultPace)
        }

        let first = segments[0][0].time!
        var previous: Date?
        var timed: [TrackPoint] = []
        var starts = Set<Int>()
        var timingIssue: String?
        for segment in segments {
            starts.insert(timed.count)
            for entry in segment {
                let time = entry.time!
                if let previous, previous > time { timingIssue = "KML 时间戳倒序。请修正后重新导入。" }
                previous = time
                timed.append(TrackPoint(latitude: entry.point.latitude, longitude: entry.point.longitude,
                                        offset: time.timeIntervalSince(first)))
            }
        }
        return TrackRoute(name: route.name, points: timed, segmentStarts: starts, timingIssue: timingIssue)
    }

    public static func withPace(_ route: TrackRoute, secondsPerKilometer: Int) -> TrackRoute {
        guard let segments = route.untimedSegments else { return route }
        var result: [TrackPoint] = []
        var starts = Set<Int>()
        var offset = 0.0
        let timedSegments = segments.map { segment in
            zip(segment, segment.dropFirst()).map { distance($0, $1) * Double(secondsPerKilometer) / 1000 }
        }
        let total = timedSegments.joined().reduce(0, +)
        let originalCount = segments.reduce(0) { $0 + $1.count }
        let interval = max(1, total / Double(max(1, 150_000 - originalCount)))
        for (segment, durations) in zip(segments, timedSegments) {
            starts.insert(result.count)
            let first = segment[0]
            result.append(TrackPoint(latitude: first.latitude, longitude: first.longitude, offset: offset))
            for (index, duration) in durations.enumerated() {
                let from = segment[index]
                let to = segment[index + 1]
                let count = max(1, Int(ceil(duration / interval)))
                let longitudeDelta = wrap(to.longitude - from.longitude)
                for step in 1...count {
                    let fraction = Double(step) / Double(count)
                    let latitude = step == count ? to.latitude : from.latitude + fraction * (to.latitude - from.latitude)
                    let longitude = step == count ? to.longitude : wrap(from.longitude + fraction * longitudeDelta)
                    result.append(TrackPoint(latitude: latitude, longitude: longitude,
                                             offset: offset + duration * fraction))
                }
                offset += duration
            }
            offset += 1
        }
        return TrackRoute(name: route.name, points: result, segmentStarts: starts,
                          timingIssue: nil, untimedSegments: segments)
    }

    private static func distance(_ a: TrackPoint, _ b: TrackPoint) -> Double {
        let rad = Double.pi / 180
        let lat = sin((b.latitude - a.latitude) * rad / 2)
        let lon = sin(wrap(b.longitude - a.longitude) * rad / 2)
        let h = lat * lat + cos(a.latitude * rad) * cos(b.latitude * rad) * lon * lon
        return 12_742_000 * asin(sqrt(min(1, max(0, h))))
    }

    private static func wrap(_ longitude: Double) -> Double {
        (longitude + 540).truncatingRemainder(dividingBy: 360) - 180
    }
}

private final class KMLReader: NSObject, XMLParserDelegate {
    fileprivate var segments: [[(point: TrackPoint, time: Date?)]] = []
    fileprivate var error: TrackError?
    private var kind: String?
    private var depth = 0
    private var trackDepth = 0
    private var field: String?
    private var text = ""
    private var points: [TrackPoint] = []
    private var dates: [Date] = []
    private var count = 0
    private let seconds = ISO8601DateFormatter()
    private let fractional = ISO8601DateFormatter()

    override init() {
        super.init()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        depth += 1
        if depth == 1 && name != "kml" { fail(parser, "请选择有效的 KML 或 KMZ 文件。") }
        if kind == nil && (name == "LineString" || (name == "Track" && namespaceURI == "http://www.google.com/kml/ext/2.2")) {
            kind = name
            trackDepth = depth
            points = []
            dates = []
        }
        guard depth == trackDepth + 1 else { return }
        if (kind == "LineString" && name == "coordinates") ||
            (kind == "Track" && (name == "when" || name == "coord")) {
            field = name
            text = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if field != nil { text += string }
    }

    func parser(_ parser: XMLParser, foundCDATA data: Data) {
        if field != nil { text += String(decoding: data, as: UTF8.self) }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        defer { depth -= 1 }
        if depth == trackDepth + 1, field == name {
            field = nil
            let values = text.split(whereSeparator: \.isWhitespace)
            if name == "when" {
                let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let date = fractional.date(from: value) ?? seconds.date(from: value) else {
                    return fail(parser, "gx:Track 含无效的时间戳。")
                }
                dates.append(date)
            } else if name == "coord" {
                append(values, parser: parser)
            } else {
                for value in values {
                    append(value.split(separator: ",", omittingEmptySubsequences: false), parser: parser)
                    if error != nil { break }
                }
            }
        }
        if depth == trackDepth, kind == name {
            if name == "Track" && dates.count != points.count && !dates.isEmpty {
                return fail(parser, "gx:Track 的时间戳和坐标数量不匹配。")
            }
            if !points.isEmpty {
                segments.append(points.enumerated().map { ($0.element, dates.isEmpty ? nil : dates[$0.offset]) })
            }
            kind = nil
        }
    }

    private func append(_ values: [Substring], parser: XMLParser) {
        guard count < 100_000, values.count >= 2,
              let lon = Double(values[0]), let lat = Double(values[1]),
              (-180...180).contains(lon), (-90...90).contains(lat) else {
            return fail(parser, "KML 含无效经纬度或轨迹点超过 10 万个。")
        }
        count += 1
        points.append(TrackPoint(latitude: lat, longitude: lon, offset: 0))
    }

    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
        fail(parser, "KML 含不支持的 XML 实体声明。")
    }

    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) {
        fail(parser, "KML 含不支持的 XML 实体声明。")
    }

    private func fail(_ parser: XMLParser, _ message: String) {
        error = TrackError(message)
        parser.abortParsing()
    }
}
