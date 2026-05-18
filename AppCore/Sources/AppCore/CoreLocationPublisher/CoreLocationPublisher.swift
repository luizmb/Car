import Combine
import CoreLocation

public struct CoreLocationPublisher: Publisher {
    public typealias Output = Event
    public typealias Failure = Error

    private let manager: CLLocationManager

    public enum Event {
        case authorizationStatus(status: CLAuthorizationStatus, accuracy: CLAccuracyAuthorization, background: Bool)
        case location(CLLocation)

        public var authorizationStatus: (status: CLAuthorizationStatus, accuracy: CLAccuracyAuthorization, background: Bool)? {
            guard case let .authorizationStatus(status, accuracy, background) = self else { return nil }
            return (status: status, accuracy: accuracy, background: background)
        }

        public var location: CLLocation? {
            guard case let .location(location) = self else { return nil }
            return location
        }
    }

    public init(manager: CLLocationManager) {
        self.manager = manager
    }

    public func receive<S: Subscriber>(subscriber: S) where S.Failure == Error, S.Input == Event {
        let subscription = Subscription(subscriber: subscriber, manager: manager)
        subscriber.receive(subscription: subscription)
    }
}

extension CoreLocationPublisher {
    class Subscription<S: Subscriber>: NSObject, Combine.Subscription, CLLocationManagerDelegate where S.Input == Output, S.Failure == Failure {
        private var buffer: DemandBuffer<S>?
        private weak var oldDelegate: CLLocationManagerDelegate?
        private var stopBeingDelegate: (() -> Void)?

        init(subscriber: S, manager: CLLocationManager) {
            buffer = DemandBuffer(subscriber: subscriber)
            super.init()
            oldDelegate = manager.delegate
            manager.delegate = self
            stopBeingDelegate = { [weak manager, weak self] in
                manager?.delegate = self?.oldDelegate
            }
        }

        func request(_ demand: Subscribers.Demand) {
            guard let buffer = self.buffer else { return }
            _ = buffer.demand(demand)
        }

        public func cancel() {
            buffer?.complete(completion: .finished)
            buffer = nil
        }

        func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
            _ = buffer?.buffer(value: .authorizationStatus(
                status: manager.authorizationStatus,
                accuracy: manager.accuracyAuthorization,
                background:manager.allowsBackgroundLocationUpdates
            ))
            oldDelegate?.locationManagerDidChangeAuthorization?(manager)
        }

        func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
            locations.forEach { _ = buffer?.buffer(value: .location($0)) }
            oldDelegate?.locationManager?(manager, didUpdateLocations: locations)
        }

        func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
            stopBeingDelegate?()
            oldDelegate?.locationManager?(manager, didFailWithError: error)
            buffer?.complete(completion: .failure(error))
            cancel()
        }

        func locationManager(_ manager: CLLocationManager, didFinishDeferredUpdatesWithError error: (any Error)?) {
            stopBeingDelegate?()
            oldDelegate?.locationManager?(manager, didFinishDeferredUpdatesWithError: error)
            buffer?.complete(
                completion: error.map(Subscribers.Completion.failure) ?? .finished
            )
            cancel()
        }

        func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
            oldDelegate?.locationManager?(manager, didUpdateHeading: newHeading)
        }

        func locationManagerShouldDisplayHeadingCalibration(_ manager: CLLocationManager) -> Bool {
            oldDelegate?.locationManagerShouldDisplayHeadingCalibration?(manager) ?? false
        }

        func locationManager(_ manager: CLLocationManager, didDetermineState state: CLRegionState, for region: CLRegion) {
            oldDelegate?.locationManager?(manager, didDetermineState: state, for: region)
        }

        @available(iOS, introduced: 7.0, deprecated: 13.0)
        func locationManager(_ manager: CLLocationManager, didRangeBeacons beacons: [CLBeacon], in region: CLBeaconRegion) {
            oldDelegate?.locationManager?(manager, didRangeBeacons: beacons, in: region)
        }

        @available(iOS, introduced: 7.0, deprecated: 13.0)
        func locationManager(_ manager: CLLocationManager, rangingBeaconsDidFailFor region: CLBeaconRegion, withError error: any Error) {
            oldDelegate?.locationManager?(manager, rangingBeaconsDidFailFor: region, withError: error)
        }

        func locationManager(_ manager: CLLocationManager, didRange beacons: [CLBeacon], satisfying beaconConstraint: CLBeaconIdentityConstraint) {
            oldDelegate?.locationManager?(manager, didRange: beacons, satisfying: beaconConstraint)
        }

        func locationManager(_ manager: CLLocationManager, didFailRangingFor beaconConstraint: CLBeaconIdentityConstraint, error: any Error) {
            oldDelegate?.locationManager?(manager, didFailRangingFor: beaconConstraint, error: error)
        }

        func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
            oldDelegate?.locationManager?(manager, didEnterRegion: region)
        }

        func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
            oldDelegate?.locationManager?(manager, didExitRegion: region)
        }

        func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: any Error) {
            oldDelegate?.locationManager?(manager, monitoringDidFailFor: region, withError: error)
        }

        @available(iOS, introduced: 4.2, deprecated: 14.0)
        func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
            oldDelegate?.locationManager?(manager, didChangeAuthorization: status)
        }

        func locationManager(_ manager: CLLocationManager, didStartMonitoringFor region: CLRegion) {
            oldDelegate?.locationManager?(manager, didStartMonitoringFor: region)
        }

        func locationManagerDidPauseLocationUpdates(_ manager: CLLocationManager) {
            oldDelegate?.locationManagerDidPauseLocationUpdates?(manager)
        }

        func locationManagerDidResumeLocationUpdates(_ manager: CLLocationManager) {
            oldDelegate?.locationManagerDidResumeLocationUpdates?(manager)
        }

        func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
            oldDelegate?.locationManager?(manager, didVisit: visit)
        }
    }
}

extension CLLocationManager {
    public var publisher: any Publisher<CoreLocationPublisher.Event, Error> {
        CoreLocationPublisher(manager: self)
    }
}
