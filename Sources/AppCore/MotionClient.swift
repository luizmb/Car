import AppDomain
import CoreMotion
import FP
import Foundation
import ReactiveConcurrency

// MARK: - Boxes

/// Created once in `World.real`. `CMMotionManager` is documented as expensive to instantiate and
/// intended to be a singleton per process — several of them fight over the hardware.
final class MotionBox: @unchecked Sendable {
    nonisolated(unsafe) let motion = CMMotionManager()
    nonisolated(unsafe) let altimeter = CMAltimeter()
    nonisolated(unsafe) let activity = CMMotionActivityManager()
}

// MARK: - Barometer

/// Pressure and relative altitude. Cold: starts on subscribe, stops when the subscription ends.
///
/// The hardware reports roughly once a second and costs almost nothing, which is a good trade for
/// the one measurement that feeds the air-density term directly.
func makeBarometerStream(box: MotionBox) -> Publisher<BarometricSample, Never> {
    Publisher { continuation in
        guard CMAltimeter.isRelativeAltitudeAvailable() else {
            continuation.finish()
            return
        }
        let (stream, streamContinuation) = AsyncStream<BarometricSample>.makeStream()

        box.altimeter.startRelativeAltitudeUpdates(to: .main) { data, _ in
            guard let data else { return }
            streamContinuation.yield(BarometricSample(
                // CoreMotion reports kilopascals already — no conversion, despite the name.
                pressure: KPa(data.pressure.doubleValue),
                relativeAltitude: Meters(data.relativeAltitude.doubleValue)
            ))
        }

        await continuation.yieldAll(stream)
        box.altimeter.stopRelativeAltitudeUpdates()
    }
}

// MARK: - Device motion

/// Accelerometer, gyro and gravity.
///
/// Sampled at 4 Hz rather than the 100 Hz the hardware offers. Every sample becomes an action, and
/// the store reconciles supervision on each state change — so a high rate would make the app spend
/// its time re-describing channels instead of riding. 4 Hz is ample for lean and braking, which are
/// physical events lasting hundreds of milliseconds, not microseconds.
func makeMotionStream(box: MotionBox) -> Publisher<MotionSample, Never> {
    Publisher { continuation in
        guard box.motion.isDeviceMotionAvailable else {
            continuation.finish()
            return
        }
        let (stream, streamContinuation) = AsyncStream<MotionSample>.makeStream()

        box.motion.deviceMotionUpdateInterval = 0.25
        box.motion.startDeviceMotionUpdates(to: .main) { data, _ in
            guard let data else { return }
            streamContinuation.yield(MotionSample(
                userAcceleration: Vector3(
                    x: data.userAcceleration.x, y: data.userAcceleration.y, z: data.userAcceleration.z
                ),
                gravity: Vector3(x: data.gravity.x, y: data.gravity.y, z: data.gravity.z),
                rotationRate: Vector3(
                    x: data.rotationRate.x, y: data.rotationRate.y, z: data.rotationRate.z
                )
            ))
        }

        await continuation.yieldAll(stream)
        box.motion.stopDeviceMotionUpdates()
    }
}

// MARK: - Activity classification

/// iOS's own guess at what you are doing. Event-driven and nearly free — it runs on the motion
/// coprocessor rather than the CPU, which is also why it can be left on indefinitely.
func makeActivityStream(box: MotionBox) -> Publisher<MotionActivitySample, Never> {
    Publisher { continuation in
        guard CMMotionActivityManager.isActivityAvailable() else {
            continuation.finish()
            return
        }
        let (stream, streamContinuation) = AsyncStream<MotionActivitySample>.makeStream()

        box.activity.startActivityUpdates(to: .main) { activity in
            guard let activity else { return }
            streamContinuation.yield(MotionActivitySample(
                activity: activity.domain,
                confidence: activity.confidence.rawValue
            ))
        }

        await continuation.yieldAll(stream)
        box.activity.stopActivityUpdates()
    }
}

private extension CMMotionActivity {
    /// Reported as flags rather than a single value — several can be true at once, which is exactly
    /// what makes a motorcycle interesting. Most specific wins; `automotive` and `cycling` are the
    /// two a bike plausibly triggers, and `cycling` is listed first so that if both fire we record
    /// the more surprising one rather than silently flattening it to `automotive`.
    var domain: MotionActivity {
        if cycling { return .cycling }
        if automotive { return .automotive }
        if running { return .running }
        if walking { return .walking }
        if stationary { return .stationary }
        return .unknown
    }
}
