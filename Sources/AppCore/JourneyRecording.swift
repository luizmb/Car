import AppDomain
import FP
import Foundation
import SpeedMonitorFeature

/// What survives into the journey log.
///
/// The debug log takes everything; this decides what is worth keeping. Two rules govern it:
///
/// - **Would this still matter in a year?** A GPS fix, a road change, a camera warning and a tyre
///   reading all would. A display rebuild, an authorisation callback and a navigation push would not
///   — they describe the app, not the ride.
/// - **Is it worth its volume?** Raw motion is 4 Hz and was 42% of one ride's log, and nothing has
///   ever been read back from it except an engine-on/off experiment done afterwards from the debug
///   file. The barometer at 0.8 Hz earns its place because road gradient feeds the fuel model;
///   the accelerometer firehose does not.
///
/// Returning `nil` means "debug only", which is the default for anything not listed.
func journeyEvent(for action: AppAction) -> (any JourneyPayloadType)? {
    if case let .speedMonitor(speed) = action { return speedMonitorEvent(speed) }
    return switch action {
    case let .indicator(.event(.indicator(side))):
        IndicatorPayload(side: side.map { $0 == .left ? "left" : "right" })
    case .indicator(.event(.connected)):
        DevicePayload(device: "indimate", connected: true)
    case .indicator(.event(.disconnected)):
        DevicePayload(device: "indimate", connected: false)
    case .chigee(.event(.present)):
        DevicePayload(device: "ignition", connected: true)
    case .chigee(.event(.absent)):
        DevicePayload(device: "ignition", connected: false)
    case .cardo(.event(.connected)):
        DevicePayload(device: "cardo", connected: true)
    case .cardo(.event(.disconnected)):
        DevicePayload(device: "cardo", connected: false)
    case let .tyres(.reading(reading)):
        TyrePayload(
            position: reading.position == .front ? "front" : "rear",
            psi: Iso<KPa, PSI>.convert.get(reading.telemetry.pressure).rawValue,
            celsius: reading.telemetry.temperature.rawValue,
            moving: reading.telemetry.isMoving
        )
    case let .weather(.observed(observation, _, _, _)):
        WeatherPayload(
            celsius: observation.temperature.rawValue,
            humidity: observation.humidity,
            kpa: observation.pressure.rawValue,
            windMPS: observation.windSpeed.rawValue,
            windDegrees: observation.windDirection.rawValue
        )
    case let .motion(.barometer(sample)):
        BarometerPayload(kpa: sample.pressure.rawValue, relativeAltitude: sample.relativeAltitude.rawValue)
    case let .motion(.activity(sample)):
        ActivityPayload(activity: sample.activity.logName, confidence: sample.confidence)
    default:
        nil
    }
}

private func speedMonitorEvent(_ action: SpeedMonitorFeature.Action) -> (any JourneyPayloadType)? {
    switch action {
    case let .locationUpdate(location):
        FixPayload(
            lat: location.latitude.rawValue,
            lon: location.longitude.rawValue,
            mph: location.speed.map { Iso<MPS, MPH>.convert.get($0).rawValue },
            course: location.course?.rawValue,
            alt: location.altitude.rawValue,
            acc: location.horizontalAccuracy?.rawValue
        )
    case let .roadSpeedChanged(info):
        RoadPayload(
            mph: info.limit.spokenValue,
            origin: info.origin.logName,
            label: info.roadLabel,
            variable: info.isVariable
        )
    case let .averageZoneChanged(zone):
        AverageZonePayload(entered: zone != nil, mph: zone?.limit?.rawValue)
    default:
        nil
    }
}

// MARK: - Stable names

// Spelled out rather than derived from `String(describing:)`. These end up in a file that outlives
// the enum cases producing them, so renaming a case must not silently rewrite a year of records.

private extension MotionActivity {
    var logName: String {
        switch self {
        case .stationary: "stationary"
        case .walking: "walking"
        case .running: "running"
        case .automotive: "automotive"
        case .cycling: "cycling"
        case .unknown: "unknown"
        }
    }
}

private extension LimitOrigin {
    var logName: String {
        switch self {
        case .signed: "signed"
        case .builtUpArea: "built-up"
        case .nationalSpeedLimit: "national"
        case .unattributed: "unattributed"
        }
    }
}

private extension RoadSpeedLimit {
    /// The figure, where there is one. `.national` has no number by definition, which is the whole
    /// reason it is a separate case.
    var spokenValue: Double? {
        if case let .value(mph) = self { mph.rawValue } else { nil }
    }
}
