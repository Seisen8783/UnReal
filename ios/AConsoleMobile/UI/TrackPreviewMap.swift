import MapKit
import SwiftUI
import TrackCore

/// MapKit polyline preview that converts WGS-84 storage coordinates to GCJ-02
/// when rendering inside mainland China so overlays match Apple Maps' China base map.
public struct TrackPreviewMap: View {
    public let route: TrackRoute?
    public let activePoint: TrackPoint?

    @State private var position: MapCameraPosition = .automatic

    public init(route: TrackRoute?, activePoint: TrackPoint?) {
        self.route = route
        self.activePoint = activePoint
    }

    public var body: some View {
        Map(position: $position) {
            if let route {
                let segments = segmentedCoordinates(for: route)
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    MapPolyline(coordinates: segment)
                        .stroke(.blue.opacity(0.75), lineWidth: 4)
                }
                if let first = route.points.first {
                    Marker("起点", coordinate: mapCoordinate(for: first))
                        .tint(.green)
                }
                if let last = route.points.last, route.points.count > 1 {
                    Marker("终点", coordinate: mapCoordinate(for: last))
                        .tint(.orange)
                }
            }
            if let activePoint {
                Annotation("当前", coordinate: mapCoordinate(for: activePoint)) {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 14, height: 14)
                        .overlay(Circle().stroke(.white, lineWidth: 2))
                }
            }
        }
        .mapStyle(.standard)
        .onChange(of: route?.points.first) { _, _ in
            updateCamera()
        }
        .onAppear {
            updateCamera()
        }
    }

    private func updateCamera() {
        guard let route, !route.points.isEmpty else { return }
        let coords = route.points.map(mapCoordinate(for:))
        let lats = coords.map(\.latitude)
        let lons = coords.map(\.longitude)
        guard let minLat = lats.min(), let maxLat = lats.max(),
              let minLon = lons.min(), let maxLon = lons.max() else { return }
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2,
                                            longitude: (minLon + maxLon) / 2)
        let span = MKCoordinateSpan(latitudeDelta: max(0.002, (maxLat - minLat) * 1.4),
                                    longitudeDelta: max(0.002, (maxLon - minLon) * 1.4))
        position = .region(MKCoordinateRegion(center: center, span: span))
    }

    private func mapCoordinate(for point: TrackPoint) -> CLLocationCoordinate2D {
        let (lon, lat) = CoordinateTransform.wgs84ToGCJ02(longitude: point.longitude,
                                                          latitude: point.latitude)
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    private func segmentedCoordinates(for route: TrackRoute) -> [[CLLocationCoordinate2D]] {
        var result: [[CLLocationCoordinate2D]] = []
        var current: [CLLocationCoordinate2D] = []
        for (index, point) in route.points.enumerated() {
            if route.segmentStarts.contains(index), !current.isEmpty {
                result.append(current)
                current = []
            }
            current.append(mapCoordinate(for: point))
        }
        if !current.isEmpty {
            result.append(current)
        }
        return result
    }
}
