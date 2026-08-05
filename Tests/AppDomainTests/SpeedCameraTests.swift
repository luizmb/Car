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
            .init(id: 1, lat: 51.75, lon: -0.47, center: nil,
                  tags: tags(enforcement: "maxspeed", maxspeed: "40 mph"))
        ])
        #expect(parseCameras(response).first?.limit == MPH(40))
    }

    @Test("a relation with only a center still yields a camera")
    func relationCenter() {
        let response = OverpassCameraResponse(elements: [
            .init(id: 2, lat: nil, lon: nil, center: .init(lat: 51.75, lon: -0.47),
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
            .init(id: 3, lat: nil, lon: nil, center: nil, tags: tags(highway: "speed_camera"))
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
