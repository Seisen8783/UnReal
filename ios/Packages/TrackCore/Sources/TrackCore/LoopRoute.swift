import Foundation
import simd

public struct LoopRoute: Sendable {
    public let centerline: [TrackPoint]
    public let sourceLaps: Int
    public let meters: Double

    public init(centerline: [TrackPoint], sourceLaps: Int, meters: Double) {
        self.centerline = centerline
        self.sourceLaps = sourceLaps
        self.meters = meters
    }

    public static func fit(_ route: TrackRoute) -> LoopRoute? {
        guard let segments = route.untimedSegments, segments.count == 1,
              let points = segments.first, points.count >= 10, let origin = points.first else { return nil }
        let latitudeScale = 111_195.0
        let longitudeScale = latitudeScale * cos(origin.latitude * .pi / 180)
        guard longitudeScale > 1 else { return nil }
        let xy = points.map {
            SIMD2(($0.longitude - origin.longitude) * longitudeScale,
                  ($0.latitude - origin.latitude) * latitudeScale)
        }
        let distances = zip(xy, xy.dropFirst()).reduce(into: [0.0]) { result, edge in
            result.append(result.last! + simd_distance(edge.0, edge.1))
        }
        guard let headingIndex = distances.firstIndex(where: { $0 >= 10 }),
              simd_length(xy[headingIndex]) > 5 else { return nil }
        let direction = simd_normalize(xy[headingIndex])
        var anchors = [0.0]
        for i in 1..<xy.count {
            let before = simd_dot(xy[i - 1], direction)
            let after = simd_dot(xy[i], direction)
            guard before < 0, after >= 0 else { continue }
            let fraction = -before / (after - before)
            let crossing = xy[i - 1] + fraction * (xy[i] - xy[i - 1])
            let distance = distances[i - 1] + fraction * (distances[i] - distances[i - 1])
            guard simd_length(crossing) <= 12, distance - anchors.last! >= 30 else { continue }
            anchors.append(distance)
        }
        let laps = zip(anchors, anchors.dropFirst()).map { ($0, $1 - $0) }
        guard laps.count >= 2, laps.count <= 100 else { return nil }
        let length = laps.map(\.1).reduce(0, +) / Double(laps.count)
        guard laps.allSatisfy({ abs($0.1 - length) < 0.12 * length }) else { return nil }

        let count = max(32, min(2048, Int(ceil(length / 2))))
        var averaged: [SIMD2<Double>] = []
        for i in 0..<count {
            let phase = Double(i) / Double(count)
            let samples = laps.map { sample(xy, distances, at: $0.0 + phase * $0.1) }
            let mean = samples.reduce(.zero, +) / Double(samples.count)
            guard samples.allSatisfy({ simd_distance($0, mean) <= 9 }) else { return nil }
            averaged.append(mean)
        }
        averaged.append(averaged[0])
        let centerline = averaged.map {
            TrackPoint(latitude: origin.latitude + $0.y / latitudeScale,
                       longitude: origin.longitude + $0.x / longitudeScale, offset: 0)
        }
        let fittedLength = zip(averaged, averaged.dropFirst()).reduce(0.0) { $0 + simd_distance($1.0, $1.1) }
        return LoopRoute(centerline: centerline, sourceLaps: laps.count, meters: fittedLength)
    }

    private static func sample(_ xy: [SIMD2<Double>], _ distances: [Double], at meters: Double) -> SIMD2<Double> {
        var lo = 0
        var hi = distances.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if distances[mid] <= meters { lo = mid } else { hi = mid }
        }
        let span = distances[hi] - distances[lo]
        guard span > 0 else { return xy[lo] }
        return xy[lo] + (meters - distances[lo]) / span * (xy[hi] - xy[lo])
    }
}
