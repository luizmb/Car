import AppDomain
import FP
import ReactiveConcurrency
import SpeedMonitorFeature
import SwiftRex
import SwiftRexArchitecture

// MARK: - The snapshot, composed

/// The phone's truth, flattened for the wrist.
///
/// Pure over `AppState`, so what the watch shows is by construction what the phone believes —
/// there is no second bookkeeping to drift. Composed on the phone rather than assembled watch-side
/// from raw feeds, because the phone is the only party that has resolved the road, run the speed
/// zone arithmetic and thinned the route.
func watchSnapshot(of state: AppState) -> WatchSnapshot {
    let display = state.speedMonitor.display
    let mph = state.speedMonitor.lastLocation?.speed
        .map { Iso<MPS, MPH>.convert.get($0).rawValue }

    let (limitMPH, limitText, national, assumed): (Double?, String?, Bool, Bool) =
        switch display.roadLimitDisplay {
        case .none, .unknown: (nil, nil, false, false)
        case let .known(text, value): (value, text, false, false)
        case let .national(text, value): (value, text, true, false)
        case .nationalOnly: (nil, nil, true, false)
        case let .assumed(text, value): (value, text, false, true)
        case let .variable(text, value): (value, text, false, false)
        }

    let over = zip(mph, limitMPH).map { speed, limit in
        speedZone(MPH(speed), limit: MPH(limit)) == .overTolerance
    } ?? false

    let route = watchRouteSample(state.speedMonitor.routeShape)

    return WatchSnapshot(
        mph: mph,
        limitMPH: limitMPH,
        limitText: limitText,
        limitIsNational: national,
        limitIsAssumed: assumed,
        overLimit: over,
        roadLabel: display.roadRef ?? display.roadName,
        indicator: state.indicator.side.map { $0 == .left ? "left" : "right" },
        latitude: state.speedMonitor.lastLocation?.latitude.rawValue,
        longitude: state.speedMonitor.lastLocation?.longitude.rawValue,
        headingDegrees: display.mapHeading,
        routeLatitudes: route.latitudes,
        routeLongitudes: route.longitudes,
        nextTurnMetres: state.speedMonitor.nextTurn?.rawValue,
        sinceFillKm: state.fuelLog.refuels.isEmpty
            ? nil : state.trip.kilometresSinceFill.rawValue,
        journeyActive: JourneyPhase.prism.active.preview(state.journey) != nil
    )
}

private func zip<A, B, C>(_ a: A?, _ b: B?, _ f: (A, B) -> C) -> C? {
    a.flatMap { justA in b.map { f(justA, $0) } }
}

private func zip<A, B>(_ a: A?, _ b: B?) -> (A, B)? {
    zip(a, b) { ($0, $1) }
}

// MARK: - The behavior

/// Everything that keeps the wrist honest, in both directions.
///
/// Outbound: after any action that can change what the watch shows — a fix, an indicator event,
/// a guidance step — the post-reduction state is flattened and pushed. Inbound: the watch's one
/// command, a refuel, is turned into exactly the record the phone's own fuel screen would write,
/// with everything only the phone knows: the clock, the position, the trip distance, the
/// forecourt.
func watchSyncBehavior() -> Behavior<AppAction, AppState, World> {

    // The command stream, subscribed once at launch and alive for the app's whole life.
    Behavior<AppAction, AppState, World>.handle { action, _ in
        guard AppAction.prism.appLaunch.preview(action) != nil else { return .doNothing }
        return .produce { ctx in
            ctx.environment.watchRefuels().asEffect(AppAction.watchRefuel)
        }
    }

    // Push the truth after anything that moves it. Post-reduction state, so the indicator event
    // being reacted to is already *in* the snapshot being sent.
    <> Behavior<AppAction, AppState, World>.handle { action, _ in
        let moves = AppAction.prism.speedMonitor.preview(action)
            .flatMap(SpeedMonitorFeature.Action.prism.locationUpdate.preview) != nil
            || AppAction.prism.indicator.preview(action) != nil
            || AppAction.prism.guidanceUpdated.preview(action) != nil
            || AppAction.prism.journeyChanged.preview(action) != nil
        guard moves else { return .doNothing }
        return .produce { ctx in
            ctx.readLiveState()
                .compactMap { state -> AppAction? in .watchSnapshotComposed(watchSnapshot(of: state)) }
                .asEffect()
        }
    }

    <> Behavior<AppAction, AppState, World>.handle { action, _ in
        guard let snapshot = AppAction.prism.watchSnapshotComposed.preview(action)
        else { return .doNothing }
        return .produce { ctx in
            ctx.environment.sendWatchSnapshot(snapshot) |> Effect.fireAndForget
        }
    }

    // A refuel ask: first resolve the forecourt, which needs a network round-trip…
    <> Behavior<AppAction, AppState, World>.handle { action, context in
        guard let refuel = AppAction.prism.watchRefuel.preview(action) else { return .doNothing }
        guard let location = context.stateBefore?.speedMonitor.lastLocation else {
            return .produce { _ in Effect.just(.watchRefuelPlaced(refuel, nil)) }
        }
        return .produce { ctx in
            ctx.environment.fetchStation(location.latitude, location.longitude)
                .asEffect { .watchRefuelPlaced(refuel, $0) }
        }
    }

    // …then write the record the fuel screen itself would have written.
    <> Behavior<AppAction, AppState, World>.handle { action, context in
        guard
            let (refuel, station) = AppAction.prism.watchRefuelPlaced.preview(action),
            let state = context.stateBefore
        else { return .doNothing }
        let location = state.speedMonitor.lastLocation
        let log = state.fuelLog
        let sinceFill = state.trip.kilometresSinceFill
        return .produce { ctx in
            let record = RefuelRecord(
                id: ctx.environment.newID(),
                date: ctx.environment.now(),
                litres: Litres(refuel.litres),
                pricePerLitre: refuel.pricePerLitre,
                // An unknown grade string from a newer watch falls back to what the bike actually
                // drinks rather than dropping the fill.
                grade: FuelGrade(rawValue: refuel.grade) ?? .e5,
                filledToBrim: refuel.filledToBrim,
                // The first fill ever has nothing to measure from — same rule as the fuel screen.
                odometer: nil,
                gpsKilometres: log.refuels.isEmpty ? nil : sinceFill,
                latitude: location?.latitude,
                longitude: location?.longitude,
                station: station
            )
            var next = log
            next.refuels.append(record)
            let keep = ctx.environment.logJourney(RefuelPayload(
                litres: record.litres.rawValue,
                price: record.pricePerLitre,
                odometer: nil,
                brim: record.filledToBrim,
                station: record.station?.label,
                stationID: record.station?.id
            )) |> Effect<AppAction>.fireAndForget
            return keep <> ctx.environment.saveFuelLog(next)
                .asEffect { (result: Result<Void, FileError>) in
                    switch result {
                    case .success: .watchRefuelApplied
                    case .failure: .watchRefuelFailed
                    }
                }
        }
    }

    // The confirmation is spoken on the bike's own audio — the rider is standing next to it at a
    // pump, and the watch's screen already shows the ack.
    <> Behavior<AppAction, AppState, World>.handle { action, _ in
        guard AppAction.prism.watchRefuelApplied.preview(action) != nil else { return .doNothing }
        return .produce { ctx in
            ctx.environment.speakQueued("Fill recorded from the watch.")
                |> Effect.fireAndForget
        }
    }

    <> Behavior<AppAction, AppState, World>.handle { action, _ in
        guard AppAction.prism.watchRefuelFailed.preview(action) != nil else { return .doNothing }
        return .produce { ctx in
            ctx.environment.speakQueued("The fill from the watch could not be saved.")
                |> Effect.fireAndForget
        }
    }
}
