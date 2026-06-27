import SwiftUI
import MapKit

struct RowPreviewMapView: UIViewRepresentable {
    let polygonPoints: [CoordinatePoint]
    let rowDirection: Double
    let rowCount: Int
    let rowWidth: Double
    var rowOffset: Double = 0
    var firstRowNumber: Int = 1
    var lastRowNumber: Int = 1
    var showRowLabels: Bool = false

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.mapType = .hybrid
        mapView.isUserInteractionEnabled = true
        mapView.isZoomEnabled = true
        mapView.isScrollEnabled = true
        mapView.isRotateEnabled = true
        mapView.delegate = context.coordinator
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        mapView.removeOverlays(mapView.overlays)
        mapView.removeAnnotations(mapView.annotations)

        guard polygonPoints.count >= 3 else { return }

        let coords: [CLLocationCoordinate2D] = polygonPoints.map { $0.coordinate }

        var polyCoords = coords
        let polygon = MKPolygon(coordinates: &polyCoords, count: polyCoords.count)
        mapView.addOverlay(polygon)

        let lines: [RowLine] = calculateRowLines(
            polygonCoords: coords,
            direction: rowDirection,
            count: rowCount,
            width: rowWidth,
            offset: rowOffset
        )
        for line in lines {
            var pts: [CLLocationCoordinate2D] = [line.start, line.end]
            let polyline = MKPolyline(coordinates: &pts, count: 2)
            mapView.addOverlay(polyline)
        }

        if showRowLabels && !lines.isEmpty {
            let firstAnnotation = RowNumberAnnotation(
                coordinate: lines[0].start,
                rowNumber: firstRowNumber
            )
            mapView.addAnnotation(firstAnnotation)

            if lines.count > 1 {
                let lastAnnotation = RowNumberAnnotation(
                    coordinate: lines[lines.count - 1].start,
                    rowNumber: lastRowNumber
                )
                mapView.addAnnotation(lastAnnotation)
            }
        }

        let lats: [Double] = coords.map(\.latitude)
        let lons: [Double] = coords.map(\.longitude)
        guard let minLat = lats.min(), let maxLat = lats.max(),
              let minLon = lons.min(), let maxLon = lons.max() else { return }

        if !context.coordinator.hasSetInitialRegion {
            let center = CLLocationCoordinate2D(
                latitude: (minLat + maxLat) / 2.0,
                longitude: (minLon + maxLon) / 2.0
            )
            let span = MKCoordinateSpan(
                latitudeDelta: (maxLat - minLat) * 1.5 + 0.001,
                longitudeDelta: (maxLon - minLon) * 1.5 + 0.001
            )
            mapView.setRegion(MKCoordinateRegion(center: center, span: span), animated: false)
            context.coordinator.hasSetInitialRegion = true
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator: NSObject, MKMapViewDelegate {
        var hasSetInitialRegion: Bool = false

        nonisolated func mapView(_ mapView: MKMapView, rendererFor overlay: any MKOverlay) -> MKOverlayRenderer {
            if let polygon = overlay as? MKPolygon {
                let r = MKPolygonRenderer(polygon: polygon)
                r.fillColor = UIColor.systemBlue.withAlphaComponent(0.1)
                r.strokeColor = UIColor.systemBlue
                r.lineWidth = 2
                return r
            }
            if let polyline = overlay as? MKPolyline {
                let r = MKPolylineRenderer(polyline: polyline)
                r.strokeColor = UIColor.systemGreen.withAlphaComponent(0.85)
                r.lineWidth = 1.5
                return r
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: any MKAnnotation) -> MKAnnotationView? {
            guard let rowAnnotation = annotation as? RowNumberAnnotation else { return nil }
            let identifier = "RowNumber"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier) ?? MKAnnotationView(annotation: annotation, reuseIdentifier: identifier)
            view.annotation = annotation

            let label = UILabel()
            label.text = "Row \(rowAnnotation.rowNumber)"
            label.font = UIFont.boldSystemFont(ofSize: 13)
            label.textColor = .white
            label.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.85)
            label.textAlignment = .center
            label.layer.cornerRadius = 6
            label.layer.masksToBounds = true
            label.sizeToFit()
            label.frame.size.width += 12
            label.frame.size.height += 6

            let renderer = UIGraphicsImageRenderer(size: label.frame.size)
            let image = renderer.image { ctx in
                label.layer.render(in: ctx.cgContext)
            }

            view.image = image
            view.centerOffset = CGPoint(x: 0, y: -15)
            view.canShowCallout = false
            return view
        }
    }
}

class RowNumberAnnotation: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D
    let rowNumber: Int

    init(coordinate: CLLocationCoordinate2D, rowNumber: Int) {
        self.coordinate = coordinate
        self.rowNumber = rowNumber
        super.init()
    }
}
