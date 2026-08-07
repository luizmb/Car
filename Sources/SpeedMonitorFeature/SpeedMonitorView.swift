import CoreLocation
import SwiftRexArchitecture
import SwiftUI

@BoundTo(SpeedMonitorFeature.self, strategy: .observationSimple)
public struct SpeedMonitorView: View {
    public var body: some View {
        SpeedMonitorContent(
            mapLatitude:        viewStore.state.cameraCentre.latitude.rawValue,
            mapLongitude:       viewStore.state.cameraCentre.longitude.rawValue,
            mapDistance:        viewStore.state.cameraDistance,
            mapHeading:         viewStore.state.cameraHeading,
            mapPitch:           viewStore.state.cameraPitch,
            speedText:          viewStore.state.speedText,
            speedValue:         viewStore.state.speedValue,
            speedAccuracyText:  viewStore.state.speedAccuracyText,
            directionText:      viewStore.state.directionText,
            courseAngleDegrees: viewStore.state.courseAngleDegrees,
            coordinatesText:    viewStore.state.coordinatesText,
            altitudeText:       viewStore.state.altitudeText,
            roadLimitDisplay:   viewStore.state.roadLimitDisplay,
            roadRef:            viewStore.state.roadRef,
            roadName:           viewStore.state.roadName,
            routeShape:         viewStore.state.routeShape.map {
                CLLocationCoordinate2D(latitude: $0.latitude.rawValue, longitude: $0.longitude.rawValue)
            }
        )
        .onAppear { viewStore.dispatch(.onAppear) }
    }
}
