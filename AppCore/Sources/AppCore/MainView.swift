import CombineRex
import MapKit
import SwiftUI

public struct MainView: View {
    @ObservedObject var viewModel: ObservableViewModel<ViewAction, ViewState>
    @Environment(\.colorScheme) var colorScheme

    public init<S: StoreType>(store: S)
    where S.ActionType == AppCore.Action, S.StateType == AppCore.State {
        self.viewModel = store.projection(
            action: \ViewAction.toStore,
            state: ViewState.from(store:)
        ).asObservableViewModel(initialState: .from(store: .initialState))
    }

    public var body: some View {

        ZStack(alignment: .bottomTrailing) {
            Map(
                position: .constant(viewModel.state.mapCameraPosition),
                interactionModes: []
            ) {
                UserAnnotation {
                    Image(systemName: "location.north.circle.fill")
                        .font(.title)
                        .foregroundColor(.blue)
                }
            }
            .mapControlVisibility(.hidden)

            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center) {
                    VStack(alignment: .center, spacing: 0) {
                        Text(viewModel.state.direction).font(.footnote)

                        Image(.windrose)
                            .resizable()
                            .aspectRatio(1, contentMode: .fit)
                            .frame(width: 80, height: 80)
                            .rotationEffect(viewModel.state.courseAngle, anchor: .center)
                    }

                    VStack(alignment: .center, spacing: 4) {
                        Text(viewModel.state.speed).font(.largeTitle)
                        Text(viewModel.state.speedAccuracy).font(.title3)
                    }
                }

                HStack(alignment: .center) {
                    Text("📡").font(.body).frame(width: 32)
                    Text(viewModel.state.coordinates).font(.footnote)
                    Spacer()
                }

                HStack(alignment: .center) {
                    Text("🏔️").font(.body).frame(width: 32)
                    Text(viewModel.state.altitude).font(.footnote)
                    Spacer()
                }

                HStack(alignment: .center) {
                    Text("🧭").font(.body).frame(width: 32)
                    Text("\(viewModel.state.authorization)/\(viewModel.state.accuracy)").font(.footnote)
                    Spacer()
                }
            }
            .frame(width: 240)
            .padding(8)
            .background((colorScheme == .light ? Color.white : Color.black).opacity(0.4))
            .cornerRadius(16)
            .padding(16)
        }
    }
}

public extension MainView {
    enum ViewAction {
        var toStore: AppCore.Action? {
            switch self {
            }
        }
    }

    struct ViewState: Equatable {
        let speed: String
        let speedAccuracy: String
        let direction: String
        let courseAngle: Angle
        let coordinates: String
        let altitude: String
        let authorization: String
        let accuracy: String
        let mapCameraPosition: MapCameraPosition

        static func from(store: AppCore.State) -> Self {
            ViewState(
                speed: (store.location.lastLocation?.speed <&> zeroWhenNegative >>> metersPerSecond >>> mph >>> formatSpeed) |> or("?"),
                speedAccuracy: (store.location.lastLocation?.speedAccuracy <&> abs >>> metersPerSecond >>> mph >>> formatSpeed >>> "±".appending) |> or(""),
                direction: (store.location.lastLocation?.course <&> directionFormat) |> or("Still"),
                courseAngle: .init(degrees: 360 - (store.location.lastLocation?.course ?? 0)),
                coordinates: Optional.zip(
                    FloatingPointFormatStyle<Double>(locale: .current).precision(.fractionLength(5)) |> Optional.some,
                    store.location.lastLocation?.coordinate.latitude,
                    store.location.lastLocation?.coordinate.longitude
                ).map(CardinalPoint.format) ?? "?",
                altitude: (store.location.lastLocation?.altitude <&> meters >>> formatLength) |> or("?"),
                authorization: {
                    switch store.location.authorizationStatus {
                    case .authorizedAlways: "Always"
                    case .notDetermined: "Not determined"
                    case .authorizedWhenInUse: "When in use"
                    case .denied: "Denied"
                    case .restricted: "Restricted"
                    @unknown default: "Not implemented"
                    }
                }(),
                accuracy: {
                    switch store.location.accuracyAuthorization {
                    case .fullAccuracy: "Full"
                    case .reducedAccuracy: "Reduced"
                    @unknown default: "Not implemented"
                    }
                }(),
                mapCameraPosition: .camera(
                    MapCamera(
                        centerCoordinate: store.location.lastLocation?.coordinate ?? .init(latitude: 0, longitude: 0),
                        distance: (store.location.lastLocation?.speed <&> constrain(4...25) >>> curry(*)(50.0)) ?? 500.0,
                        heading: store.location.lastLocation?.course ?? 0,
                        pitch: 60
                    )
                )
            )
        }
    }
}

let zeroWhenNegative = (0.0 as Double) |> (max |> curry)
let constrain = { (range: ClosedRange<Double>) in curry(max)(range.lowerBound) >>> curry(min)(range.upperBound) }
let metersPerSecond = UnitSpeed.metersPerSecond |> (Measurement<UnitSpeed>.init |> flip)
let meters = UnitLength.meters |> (Measurement<UnitLength>.init |> flip)
let mph = UnitSpeed.milesPerHour |> (Measurement<UnitSpeed>.converted |> flip)
let formatSpeed = Measurement<UnitSpeed>.FormatStyle(
    width: .abbreviated,
    usage: .asProvided,
    numberFormatStyle: .init().precision(.fractionLength(0))
) |> flip(Measurement<UnitSpeed>.formatted)
let formatSpeedSpeech = mph >>> ^\.value >>> FloatingPointFormatStyle<Double>(locale: .current).precision(.fractionLength(0)) |> flip(Double.formatted)
let formatLength = Measurement<UnitLength>.FormatStyle(
    width: .abbreviated,
    usage: .asProvided,
    numberFormatStyle: .init().precision(.fractionLength(2))
) |> flip(Measurement<UnitLength>.formatted)
let directionFormat = { (d: Double) in
    var d = d
    while d >= 360 { d = d - 360 }
    let format = FloatingPointFormatStyle<Double>(locale: .current).precision(.fractionLength(1))

    return (CompassDirection8(degrees: d) <&> \.rawValue >>> curry(+)(" ") >>> curry(+)(d.formatted(format))) ?? "Still"
}
