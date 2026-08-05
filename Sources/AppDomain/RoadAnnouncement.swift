import FP

/// What to say when the road changes — "30 zone, High Street".
///
/// Pure, and separate from the effect that speaks it, because the wording is the part that was
/// wrong. On a real ride the same app said "30 zone" on one street, "national speed" on the next and
/// "national speed, 30" on a third, which reads as a broken app but was in fact four different OSM
/// tagging situations all being described with the same two words.
///
/// The rules, in order of how much they can be trusted:
///
/// | Situation | Spoken |
/// |---|---|
/// | Explicit `maxspeed` tag | "30 zone" |
/// | Inferred from a built-up classification | "built-up area, 30" |
/// | Inferred as the national speed limit | "national speed limit, 60" |
/// | National, class unresolvable | "national speed limit" |
/// | Variable (smart motorway) | "70, variable" |
/// | Nothing at all | just the road name, or silence |
///
/// The distinction that matters most: "national speed limit" is a specific legal thing meaning 60 or
/// 70, so attaching it to a residential 30 — as this once did — is not a wording nicety but a false
/// statement, and one the rider can immediately see is false.
public func roadAnnouncement(
    _ info: RoadInfo,
    formatSpeed: (MPH) -> String
) -> String {
    // A variable limit still gets its number spoken. OSM's figure is the default the gantries start
    // from, so it is the best guess available — and the over/under announcements need a figure to
    // work against, where silence would disable them entirely. "Variable" is appended so the rider
    // knows to believe the signs over us.
    let limitText: String?
    switch info.limit {
    case .unknown:
        limitText = info.isVariable ? "variable limit" : nil

    case .national:
        // Subject to national limits but the class is ambiguous, so there is genuinely no number.
        limitText = info.isVariable ? "national speed limit, variable" : "national speed limit"

    case .value(let mph):
        let spoken = formatSpeed(mph)
        if info.isVariable {
            limitText = "\(spoken), variable"
        } else {
            switch info.origin {
            // A surveyed sign — plain and unqualified, being the one case we are sure of.
            case .signed:
                limitText = "\(spoken) zone"
            // The built-up-area default, which is not the national speed limit. Naming it separates
            // an inferred 30 from a signed one without asserting something untrue of a housing estate.
            case .builtUpArea:
                limitText = "built-up area, \(spoken)"
            // Genuinely the NSL, so name it and give the figure being ridden against.
            case .nationalSpeedLimit:
                limitText = "national speed limit, \(spoken)"
            case .unattributed:
                limitText = spoken
            }
        }
    }

    // An unnamed limit and an unlimited name are independently useful, so each is spoken whenever it
    // is there. Only a road with neither says nothing at all.
    return [limitText, info.roadLabel].compactMap(id).joined(separator: ", ")
}
