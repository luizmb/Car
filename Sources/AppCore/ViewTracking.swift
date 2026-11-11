import AppDomain
import FP
import SwiftRexSwiftUI

// MARK: - Values the views read whole
//
// A view store hands back a value — and records a dependency on that one path — only for types that are
// `IndivisibleTracking`; anything else comes back as a position to read into. These are the small domain
// values the screens switch on or show as a unit, where reading field by field would buy nothing.
//
// Declared here rather than in `AppDomain`: the domain does not know a view layer exists
// (see "dependencies die at World"). `SpeedMonitorFeature` declares its own few the same way.

extension Side: IndivisibleTracking {}
extension BluetoothAvailability: IndivisibleTracking {}
extension BatteryReading: IndivisibleTracking {}
extension AudioOutput: IndivisibleTracking {}
extension MaintenanceStatus: IndivisibleTracking {}
extension FuelTab: IndivisibleTracking {}
extension ConsumptionDisplay: IndivisibleTracking {}

/// Kilometres, litres and the other unit-tagged numbers: a number is read whole, whatever its tag.
extension Newtype: @retroactive IndivisibleTracking where RawValue: IndivisibleTracking {}
