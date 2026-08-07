import Foundation
import Testing
@testable import AppDomain

// The brief was "be as comprehensive as possible with cameras, and don't skip cameras if the vector
// isn't perfectly aligned". Both halves are asymmetric on purpose: a camera we failed to mention
// costs a fine, a camera mentioned needlessly costs a short sentence. Everything below leans that
// way, and the tests exist to stop a later tidy-up quietly making it strict.

private func tags(
    highway: String? = nil, enforcement: String? = nil, maxspeed: String? = nil,
    direction: String? = nil, speedCamera: String? = nil, device: String? = nil
) -> OverpassCameraResponse.Element.Tags {
    .init(
        highway: highway, enforcement: enforcement, maxspeed: maxspeed,
        direction: direction, speedCamera: speedCamera, device: device
    )
}

@Suite("Camera tagging")
struct CameraKindTests {

    @Test("a plain speed_camera node is a fixed camera")
    func plainNode() {
        #expect(cameraKind(from: tags(highway: "speed_camera")) == .fixed)
    }

    @Test("enforcement relations map to their kind")
    func enforcementKinds() {
        #expect(cameraKind(from: tags(enforcement: "maxspeed")) == .fixed)
        #expect(cameraKind(from: tags(enforcement: "average_speed")) == .average)
        #expect(cameraKind(from: tags(enforcement: "traffic_signals")) == .redLight)
    }

    @Test("mobile sites are recognised from either tag")
    func mobileSites() {
        #expect(cameraKind(from: tags(highway: "speed_camera", speedCamera: "mobile")) == .mobile)
        #expect(cameraKind(from: tags(enforcement: "maxspeed", device: "mobile")) == .mobile)
    }

    @Test("an unrecognised enforcement kind is still a camera")
    func unknownEnforcementSurvives() {
        // Vaguer wording is the right response to an unfamiliar tag; silence is not.
        #expect(cameraKind(from: tags(enforcement: "check")) == .unknown)
    }

    @Test("unrelated nodes are not cameras")
    func nonCameras() {
        #expect(cameraKind(from: tags(highway: "traffic_signals")) == nil)
        #expect(cameraKind(from: tags()) == nil)
    }

    @Test("direction parses degrees and compass points, and gives up on relative ones")
    func directions() {
        #expect(parseDirection("180") == 180)
        #expect(parseDirection("SW") == 225)
        #expect(parseDirection("n") == 0)
        // Relative to a way we never fetched — unknown, which is the same as absent here.
        #expect(parseDirection("forward") == nil)
        #expect(parseDirection(nil) == nil)
    }

    @Test("the enforced limit is read from the camera, not the road")
    func enforcedLimit() {
        // The point of carrying it separately: a camera can enforce something the road does not.
        let response = OverpassCameraResponse(elements: [
            .init(id: 1, lat: 51.75, lon: -0.47, center: nil, geometry: nil, members: nil,
                  tags: tags(enforcement: "maxspeed", maxspeed: "40 mph"))
        ])
        #expect(parseCameras(response).first?.limit == MPH(40))
    }

    @Test("a relation with only a center still yields a camera")
    func relationCenter() {
        let response = OverpassCameraResponse(elements: [
            .init(id: 2, lat: nil, lon: nil, center: .init(lat: 51.75, lon: -0.47), geometry: nil, members: nil,
                  tags: tags(enforcement: "average_speed", maxspeed: "50 mph"))
        ])
        let camera = parseCameras(response).first
        #expect(camera?.kind == .average)
        #expect(camera?.latitude == Latitude(51.75))
    }

    @Test("an element with no position at all is dropped")
    func noPositionDropped() {
        // Cannot warn about something we cannot locate; guessing would be worse than omitting.
        let response = OverpassCameraResponse(elements: [
            .init(id: 3, lat: nil, lon: nil, center: nil, geometry: nil, members: nil, tags: tags(highway: "speed_camera"))
        ])
        #expect(parseCameras(response).isEmpty)
    }
}

@Suite("Camera selection")
struct CameraSelectionTests {

    private let here = (Latitude(51.75), Longitude(-0.475))

    /// A camera `metres` away on the given compass bearing.
    private func camera(_ id: Int, metres: Double, bearing: Double, limit: MPH? = MPH(30)) -> SpeedCamera {
        let radians = bearing * .pi / 180
        let north = metres * cos(radians)
        let east = metres * sin(radians)
        return SpeedCamera(
            id: id, kind: .fixed,
            latitude: Latitude(51.75 + north / 111_320),
            longitude: Longitude(-0.475 + east / (111_320 * cos(51.75 * .pi / 180))),
            limit: limit, direction: nil
        )
    }

    @Test("lookahead scales with speed and is clamped at both ends")
    func lookahead() {
        // 200 m is fifteen seconds at 30 mph and five at 70 — a fixed distance gives least warning
        // exactly where most is needed.
        #expect(lookaheadDistance(speed: MPS(13.4)).rawValue == 268)          // ~30 mph
        #expect(lookaheadDistance(speed: MPS(0)).rawValue == 200)             // floor
        #expect(lookaheadDistance(speed: MPS(100)).rawValue == 1_200)         // ceiling
    }

    @Test("a camera straight ahead is returned")
    func straightAhead() {
        let ahead = camerasAhead([camera(1, metres: 200, bearing: 0)], at: here, course: Course(0), speed: MPS(13.4))
        #expect(ahead.map(\.id) == [1])
    }

    @Test("a camera behind is not")
    func behindExcluded() {
        #expect(camerasAhead([camera(1, metres: 200, bearing: 180)], at: here, course: Course(0), speed: MPS(13.4)).isEmpty)
    }

    @Test("a camera well off the nose is still announced")
    func generousCone() {
        // The explicit ask: do not skip cameras because the vector is not perfectly aligned. At 80°
        // off — a camera round a bend you are about to take — it must still be called.
        let ahead = camerasAhead([camera(1, metres: 200, bearing: 80)], at: here, course: Course(0), speed: MPS(13.4))
        #expect(ahead.map(\.id) == [1])
    }

    @Test("with no course, nothing can be ruled out")
    func noCourseKeepsEverything() {
        let cameras = [camera(1, metres: 150, bearing: 0), camera(2, metres: 150, bearing: 180)]
        #expect(camerasAhead(cameras, at: here, course: nil, speed: MPS(0)).count == 2)
    }

    @Test("cameras beyond the lookahead are held back")
    func beyondReach() {
        // Not dropped forever — the same camera returns once you are going fast enough that the
        // warning is useful. At 30 mph the reach is 268 m; at 70 mph it is 620 m.
        let far = camera(1, metres: 500, bearing: 0)
        #expect(camerasAhead([far], at: here, course: Course(0), speed: MPS(13.4)).isEmpty)
        #expect(camerasAhead([far], at: here, course: Course(0), speed: MPS(31)).count == 1)
    }

    @Test("nearest comes first")
    func sortedByDistance() {
        let cameras = [camera(1, metres: 250, bearing: 10), camera(2, metres: 90, bearing: 350)]
        #expect(camerasAhead(cameras, at: here, course: Course(0), speed: MPS(13.4)).map(\.id) == [2, 1])
    }

    @Test("a camera facing away is still announced")
    func directionNeverExcludes() {
        // `direction` is absent or relative on a great many cameras, and one tagged as facing the
        // other way may still be on your carriageway. Recorded, never used to filter.
        let facingAway = SpeedCamera(
            id: 1, kind: .fixed,
            latitude: Latitude(51.7518), longitude: Longitude(-0.475),
            limit: MPH(30), direction: 180
        )
        #expect(camerasAhead([facingAway], at: here, course: Course(0), speed: MPS(13.4)).map(\.id) == [1])
    }
}

@Suite("Camera announcements")
struct CameraAnnouncementTests {

    private let speak: (MPH) -> String = { String(Int($0.rawValue)) }

    private func camera(_ kind: CameraKind, limit: MPH?) -> SpeedCamera {
        SpeedCamera(id: 1, kind: kind, latitude: Latitude(51.75), longitude: Longitude(-0.475),
                    limit: limit, direction: nil)
    }

    @Test("under the limit still gets the full sentence, including your speed")
    func underLimit() {
        // Asked for explicitly. On a bike with no working instruments, "thirty, you're at twenty-four"
        // is the reassurance that stops you looking down at the phone.
        #expect(cameraAnnouncement(camera(.fixed, limit: MPH(30)), currentSpeed: MPH(24), formatSpeed: speak)
                == "Speed camera ahead, 30, you're at 24.")
    }

    @Test("over the limit adds the instruction")
    func overLimit() {
        #expect(cameraAnnouncement(camera(.fixed, limit: MPH(30)), currentSpeed: MPH(34), formatSpeed: speak)
                == "Speed camera ahead, 30, you're at 34, slow down.")
    }

    @Test("exactly on the limit is not over")
    func exactlyOnLimit() {
        #expect(!cameraAnnouncement(camera(.fixed, limit: MPH(30)), currentSpeed: MPH(30), formatSpeed: speak)
                .contains("slow down"))
    }

    @Test("an untagged limit still announces the camera and your speed")
    func noLimitKnown() {
        #expect(cameraAnnouncement(camera(.fixed, limit: nil), currentSpeed: MPH(34), formatSpeed: speak)
                == "Speed camera ahead, you're at 34.")
    }

    @Test("each kind gets its own words")
    func kindWording() {
        #expect(cameraAnnouncement(camera(.average, limit: MPH(50)), currentSpeed: MPH(48), formatSpeed: speak)
                .hasPrefix("Average speed check"))
        #expect(cameraAnnouncement(camera(.redLight, limit: nil), currentSpeed: MPH(28), formatSpeed: speak)
                .hasPrefix("Red light camera"))
        #expect(cameraAnnouncement(camera(.mobile, limit: MPH(30)), currentSpeed: MPH(29), formatSpeed: speak)
                .hasPrefix("Mobile camera site"))
        #expect(cameraAnnouncement(camera(.unknown, limit: nil), currentSpeed: MPH(29), formatSpeed: speak)
                .hasPrefix("Camera"))
    }
}

@Suite("Average-speed zones")
struct AverageZoneTests {

    private func at(_ metresNorth: Double) -> Coordinate {
        Coordinate(latitude: Latitude(51.75 + metresNorth / 111_320), longitude: Longitude(-0.475))
    }

    private func zone(start: Double?, end: Double?, limit: MPH? = MPH(50)) -> AverageZone {
        AverageZone(
            id: 7, limit: limit,
            start: start.map(at), end: end.map(at)
        )
    }

    @Test("from and to members are read off the relation")
    func membersParsed() {
        let response = OverpassCameraResponse(elements: [
            .init(id: 7, lat: nil, lon: nil, center: nil, geometry: nil, members: [
                .init(type: "node", role: "from", lat: 51.75, lon: -0.475, geometry: nil),
                .init(type: "node", role: "to", lat: 51.80, lon: -0.475, geometry: nil),
                .init(type: "node", role: "device", lat: 51.77, lon: -0.475, geometry: nil)
            ], tags: tags(enforcement: "average_speed", maxspeed: "50 mph"))
        ])
        let parsed = parseAverageZones(response).first
        #expect(parsed?.limit == MPH(50))
        #expect(parsed?.start?.latitude == Latitude(51.75))
        #expect(parsed?.end?.latitude == Latitude(51.80))
    }

    @Test("a way member contributes its first point")
    func wayMemberPosition() {
        // `from`/`to` are often ways rather than nodes, in which case the geometry is where the
        // boundary is.
        let response = OverpassCameraResponse(elements: [
            .init(id: 7, lat: nil, lon: nil, center: nil, geometry: nil, members: [
                .init(type: "way", role: "from", lat: nil, lon: nil,
                      geometry: [.init(lat: 51.75, lon: -0.475), .init(lat: 51.76, lon: -0.475)])
            ], tags: tags(enforcement: "average_speed"))
        ])
        #expect(parseAverageZones(response).first?.start?.latitude == Latitude(51.75))
    }

    @Test("entering is detected at the start gantry")
    func enters() {
        let z = zone(start: 0, end: 5_000)
        #expect(averageZoneEntered(zones: [z], cameras: [], at: at(100), currentZone: nil)?.id == 7)
        #expect(averageZoneEntered(zones: [z], cameras: [], at: at(3_000), currentZone: nil) == nil)
    }

    @Test("the zone you are already in is not re-entered")
    func noReentry() {
        let z = zone(start: 0, end: 5_000)
        #expect(averageZoneEntered(zones: [z], cameras: [], at: at(100), currentZone: z) == nil)
    }

    @Test("with no from member, the first average camera is the entrance")
    func fallsBackToCameras() {
        // Plenty of zones are mapped as devices only; erring toward warning early is the right way
        // to be wrong here.
        let z = zone(start: nil, end: 5_000)
        let device = SpeedCamera(
            id: 9, kind: .average,
            latitude: at(50).latitude, longitude: at(50).longitude,
            limit: MPH(50), direction: nil
        )
        #expect(averageZoneEntered(zones: [z], cameras: [device], at: at(0), currentZone: nil)?.id == 7)
    }

    @Test("leaving is detected at the end gantry")
    func exits() {
        let z = zone(start: 0, end: 5_000)
        #expect(averageZoneExited(z, at: at(4_900)))
        #expect(!averageZoneExited(z, at: at(2_000)))
    }

    @Test("a zone with no end is never exited on geometry")
    func noEndNeverExits() {
        // Nothing to measure against. The feature drops it when the zone leaves the fetched area;
        // announcing an end we cannot see would be worse than staying quiet.
        #expect(!averageZoneExited(zone(start: 0, end: nil), at: at(9_999)))
    }

    @Test("the wording distinguishes beginning, being inside, and ending")
    func wording() {
        let speak: (MPH) -> String = { String(Int($0.rawValue)) }
        let z = zone(start: 0, end: 5_000)
        #expect(averageZoneStartAnnouncement(z, currentSpeed: MPH(48), formatSpeed: speak)
                == "Average speed check begins, 50, you're at 48.")
        // Not "slow down" — inside a zone the instantaneous reading is not the offence.
        #expect(averageZoneOverLimitAnnouncement(z, currentSpeed: MPH(54), formatSpeed: speak)
                .contains("your average is what counts"))
        #expect(averageZoneEndAnnouncement(z) == "Average speed check ends.")
    }
}

// MARK: - Cameras on the road beside

@Suite("Cameras that belong to another road")
struct CameraPlausibilityTests {
    private func camera(_ id: Int, _ mph: Double?) -> SpeedCamera {
        SpeedCamera(
            id: id, kind: .fixed,
            latitude: Latitude(51.86), longitude: Longitude(-0.417),
            limit: mph.map { MPH($0) }, direction: nil
        )
    }

    /// Six real cameras were announced on a 30 mph stretch of the A1081, every one of them five to
    /// eight metres from a `trunk_link` — the M1 slip roads alongside. At a junction every road is
    /// within a few tens of metres of every other, so distance cannot separate them; the limit can.
    @Test("A camera claiming a much higher limit than the road is watching another road")
    func dropsFasterCameras() {
        let kept = plausible([camera(1, 50)], onRoadLimited: MPH(30))
        #expect(kept.isEmpty)
    }

    /// Deliberately one-directional. A camera claiming *less* than the road is what roadworks look
    /// like, and those are ours — suppressing a real camera costs a fine.
    @Test("A camera claiming a lower limit is kept")
    func keepsSlowerCameras() {
        #expect(plausible([camera(1, 30)], onRoadLimited: MPH(60)).count == 1)
    }

    /// The tolerance is for rounding only. It was ten, and UK limits step by ten — so it admitted
    /// exactly the neighbouring tier, and "speed camera ahead, 50" fired three times on a 40 mph
    /// stretch from the A1081 cameras alongside.
    @Test("An equal limit survives; the next tier up does not")
    func keepsNearEqual() {
        #expect(plausible([camera(1, 40)], onRoadLimited: MPH(30)).isEmpty)
        #expect(plausible([camera(2, 30)], onRoadLimited: MPH(30)).count == 1)
        #expect(plausible([camera(3, 50)], onRoadLimited: MPH(40)).isEmpty)
    }

    /// Most cameras carry no limit at all, and an unknown one says nothing about which road it is
    /// on — so it is kept, since a missed camera is the expensive error.
    @Test("A camera with no limit is kept")
    func keepsUnknown() {
        #expect(plausible([camera(1, nil)], onRoadLimited: MPH(30)).count == 1)
    }

    /// With no known road limit there is nothing to compare against.
    @Test("With no road limit nothing is dropped")
    func keepsAllWithoutRoadLimit() {
        #expect(plausible([camera(1, 70)], onRoadLimited: nil).count == 1)
    }

    /// "Average speed check, 50" was heard on a 30 mph street for the same reason.
    @Test("The same rule applies to average-speed zones")
    func zonesToo() {
        let zone = AverageZone(id: 1, limit: MPH(50), start: nil, end: nil)
        #expect(plausible([zone], onRoadLimited: MPH(30)).isEmpty)
        #expect(plausible([zone], onRoadLimited: MPH(50)).count == 1)
    }
}
