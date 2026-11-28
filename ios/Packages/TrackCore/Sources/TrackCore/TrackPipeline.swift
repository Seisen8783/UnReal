import Foundation

/// Shared track normalization, calibration, centerline fitting, kilometer expansion,
/// and display formatting used identically by macOS and iOS consoles.
public enum TrackPipeline {
    public struct BuiltRoute: Sendable {
        public let route: TrackRoute
        public let loop: LoopRoute?

        public init(route: TrackRoute, loop: LoopRoute?) {
            self.route = route
            self.loop = loop
        }
    }

    /// Runs the canonical route build pipeline: coordinate normalization -> optional GCJ-02 pullback
    /// -> metric calibration shift -> optional loop centerline fit -> pace synthesis -> kilometer expansion.
    public static func build(original: TrackRoute,
                             coordinateSystem: CoordinateSystem,
                             reportAlignment: ReportAlignment,
                             calibration: CalibrationOffset,
                             useCenterline: Bool,
                             geometryPaceSeconds: Int,
                             targetMeters: Double?) -> BuiltRoute {
        var source = coordinateSystem.normalized(route: original)
        if reportAlignment == .pullBackOneDatum {
            source = CoordinateSystem.gcj02.normalized(route: source)
        }
        let shiftedPoints = calibration.apply(to: source.points)
        let shiftedSegments = source.untimedSegments.map { segments in
            segments.map { calibration.apply(to: $0) }
        }
        source = TrackRoute(name: source.name,
                            points: shiftedPoints,
                            segmentStarts: source.segmentStarts,
                            timingIssue: source.timingIssue,
                            untimedSegments: shiftedSegments)

        var fittedLoop: LoopRoute?
        if useCenterline, let fitted = LoopRoute.fit(source) {
            fittedLoop = fitted
            source.untimedSegments = [fitted.centerline]
        }

        var built = KMLRoute.withPace(source, secondsPerKilometer: geometryPaceSeconds)
        if let targetMeters, let expanded = expand(toMeters: targetMeters, route: built,
                                                   paceSecondsPerKilometer: Double(geometryPaceSeconds)) {
            built = expanded
        }
        return BuiltRoute(route: built, loop: fittedLoop)
    }

    /// Expands or truncates a route to the exact target arc length in meters.
    public static func expand(toMeters target: Double, route: TrackRoute,
                              paceSecondsPerKilometer: Double) -> TrackRoute? {
        guard route.points.count > 1 else { return route }
        let single = TrackMetrics.length(route.points)
        guard single > 0 else { return route }

        var untimed: [[TrackPoint]]? = nil
        if let segments = route.untimedSegments {
            untimed = segments.map {
                TrackMetrics.expand(toMeters: target, points: $0,
                                    paceSecondsPerKilometer: paceSecondsPerKilometer)
            }
        }

        var points = route.points
        if route.untimedSegments == nil {
            points = TrackMetrics.expand(toMeters: target, points: points,
                                         paceSecondsPerKilometer: paceSecondsPerKilometer)
        }

        return TrackRoute(name: route.name,
                          points: points,
                          segmentStarts: [0],
                          timingIssue: route.timingIssue,
                          untimedSegments: untimed)
    }

    /// Estimates landing error (meters) between the reported GCJ-02 point and the true WGS-84 origin.
    public static func reportLandingErrorMeters(route: TrackRoute,
                                                original: TrackRoute,
                                                effectiveSystem: CoordinateSystem,
                                                calibration: CalibrationOffset) -> Double? {
        guard let first = route.points.first, let origin = original.points.first else { return nil }
        let truePoint = calibration.apply(to: effectiveSystem.normalized(origin))
        let reported = CoordinateTransform.wgs84ToGCJ02(longitude: first.longitude, latitude: first.latitude)
        return TrackMetrics.meters(truePoint,
                                   TrackPoint(latitude: reported.1, longitude: reported.0, offset: truePoint.offset))
    }

    public static func formatMeters(_ meters: Double) -> String {
        guard meters.isFinite, meters >= 0 else { return "0m" }
        if meters < 1000 {
            return String(format: "%.1fm", meters)
        }
        return String(format: "%.2fkm", meters / 1000)
    }

    public static func formatDuration(_ seconds: Double) -> String {
        let total = Int(max(0, seconds))
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%02d:%02d", total / 60, total % 60)
    }
}
