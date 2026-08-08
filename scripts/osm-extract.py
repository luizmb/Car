"""Reduce an OSM extract to only what SpeedJarvis asks Overpass for.

Roads (name, ref, class, speed limit, geometry), enforcement cameras, average-speed zones and petrol
stations. Everything else is discarded.

Coordinates are packed as int32 at 1e-7 degrees — about a centimetre, which is far finer than GPS —
rather than the 8-byte doubles a GeoPackage stores. That alone halves the file, and geometry was 76%
of it when measured on Bedfordshire.

The `meta` table records the extract's bounding box, and that is not decoration: outside it, "no
cameras near here" and "no data for here" are the same empty result, and the app has to be able to
tell them apart to know whether to ask the network. Ride to France and every lookup falls through to
Overpass, which is exactly right.
"""
import math
import osmium
import sqlite3
import struct
import sys
import time

# Matches `isRideable` in RoadSelection.swift. Footways, paths, cycleways and steps are dropped
# outright: being two metres from a pavement says nothing about which road you are on.
RIDEABLE = {
    "motorway", "motorway_link", "trunk", "trunk_link", "primary", "primary_link",
    "secondary", "secondary_link", "tertiary", "tertiary_link",
    "unclassified", "residential", "living_street", "service", "track", "road",
}
# Stored as a small int rather than a string, repeated a million times.
#
# Computed over the whole of RIDEABLE even though not all of it is kept, so the numbers stay put:
# `classNames` in LocalRoadStore.swift is a positional array, and dropping a class from this set
# would renumber everything after it and silently turn every trunk road into a track.
CLASS_ID = {name: i for i, name in enumerate(sorted(RIDEABLE))}

# Kept out of the file, not out of the classification.
#
# Tracks are unsurfaced farm and forest ways. Nobody is riding a VT400 down one, and 360,000 of them
# with full geometry cost about 40 MB — while sitting close enough to real roads to compete for the
# match. `isRideable` still knows the class and `classPenalty` still penalises it, so an extract that
# does include them keeps working.
SKIP = {"track"}

COMPASS = {
    "n": 0, "nne": 22.5, "ne": 45, "ene": 67.5,
    "e": 90, "ese": 112.5, "se": 135, "sse": 157.5,
    "s": 180, "ssw": 202.5, "sw": 225, "wsw": 247.5,
    "w": 270, "wnw": 292.5, "nw": 315, "nnw": 337.5,
}


def parse_mph(raw):
    """OSM `maxspeed` as mph. `national` and unparseable values resolve to None — the app already
    infers those from the road class, and a wrong number is worse than an absent one."""
    if not raw:
        return None
    raw = raw.strip().lower()
    parts = raw.split()
    try:
        value = float(parts[0])
    except (ValueError, IndexError):
        return None
    if len(parts) > 1 and parts[1].startswith("km"):
        return int(round(value / 1.609344))
    return int(round(value))


def parse_lanes(raw):
    """OSM `lanes` as a small int. Values like "2; 3" or "narrow" resolve to None — the turn
    string itself carries a lane count (its pipe count), so this is corroboration, not the law."""
    if not raw:
        return None
    try:
        return int(raw.strip())
    except ValueError:
        return None


def parse_oneway(raw):
    """1 forward-only, -1 reversed (travel runs against the geometry), 0 both ways, None untagged."""
    if not raw:
        return None
    raw = raw.strip().lower()
    if raw in ("yes", "true", "1"):
        return 1
    if raw == "-1":
        return -1
    if raw in ("no", "false", "0"):
        return 0
    return None


def parse_direction(raw):
    """Compass degrees from a number or a cardinal abbreviation.

    `forward`/`backward` are relative to a way we are not storing, so they resolve to None. That
    matches `parseDirection` in SpeedCamera.swift, and costs nothing: direction is recorded but
    never used to exclude a camera."""
    if not raw:
        return None
    raw = raw.strip().lower()
    try:
        return float(raw) % 360
    except ValueError:
        return COMPASS.get(raw)


def camera_kind(tags):
    """Mirrors `cameraKind(from:)` in SpeedCamera.swift. None means "not an enforcement device"."""
    mobile = tags.get("speed_camera", "").lower() == "mobile" or tags.get("device", "").lower() == "mobile"
    enforcement = tags.get("enforcement", "").lower()
    if enforcement == "average_speed":
        return "average"
    if enforcement == "traffic_signals":
        return "redLight"
    if enforcement in ("maxspeed", "speed"):
        return "mobile" if mobile else "fixed"
    if enforcement:
        return "unknown"
    if tags.get("highway", "").lower() != "speed_camera":
        return None
    return "mobile" if mobile else "fixed"


def pack(coords):
    """Latitude/longitude pairs as int32 at 1e-7 degrees."""
    out = bytearray()
    for lat, lon in coords:
        out += struct.pack("<ii", int(round(lat * 1e7)), int(round(lon * 1e7)))
    return bytes(out)


class RelationScan(osmium.SimpleHandler):
    """Pass one: enforcement relations, and nothing else.

    Relations come last in a PBF, so by the time one is read the nodes it points at have long
    streamed past. Reading them up front is what makes a zone's geometry resolvable in a single
    subsequent pass — and reading *only* relations is cheap, because no node-location index is
    needed and the node and way blocks are skipped outright.
    """
    def __init__(self):
        super().__init__()
        self.zones = {}
        self.devices = {}
        self.nodes = set()
        self.ways = set()

    def relation(self, r):
        tags = dict(r.tags)
        # `type=enforcement` covers every enforcement device, most of which are ordinary point
        # cameras that happen to be mapped as a relation with `from`/`to` context. Only
        # `average_speed` is a zone, and the distinction is not cosmetic: a 17-metre "zone" built
        # from a 30 mph point camera would have the rider told an average check had begun and then
        # ended, for a device that measures a single instant. Matches `parseAverageZones`.
        #
        # The devices themselves are not lost — they are nodes, and they were already captured as
        # cameras in their own right.
        if tags.get("type") != "enforcement" or tags.get("enforcement", "").lower() != "average_speed":
            return
        roles = {}
        for member in r.members:
            role = member.role or ""
            # **The members are the zone.** A relation's id and speed alone — which the first
            # version of this script stored — cannot say where anything is.
            if role in ("from", "to") and role not in roles:
                roles[role] = (member.type, member.ref)
                (self.nodes if member.type == "n" else self.ways).add(member.ref)
            elif role == "device" and member.type == "n":
                # The gantries themselves. Stored because 31 of England's 67 zones carry no
                # `from`/`to` at all, and for those the devices are the only thing that says where
                # the zone is. Nothing reads this column yet — `averageZoneEntered` currently falls
                # back to nearby cameras tagged `enforcement=average_speed`, of which the whole
                # country has thirty, so those zones can never be entered. Extracting it now costs
                # nothing and means the fix does not need another full rebuild.
                self.devices.setdefault(r.id, []).append(member.ref)
                self.nodes.add(member.ref)
        self.zones[r.id] = (parse_mph(tags.get("maxspeed")), roles)


class Extractor(osmium.SimpleHandler):
    def __init__(self, db, wanted_nodes=frozenset(), wanted_ways=frozenset()):
        super().__init__()
        self.db = db
        # Positions for the handful of nodes and ways that bound a zone. These are ordinary
        # junction nodes carrying no tags at all — not cameras, not anything this script would
        # otherwise keep — so they have to be asked for by id.
        self.wanted_nodes = wanted_nodes
        self.wanted_ways = wanted_ways
        self.located = {}
        self.roads = []
        self.cameras = []
        self.stations = []
        self.seen = 0
        self.started = time.time()
        # Computed rather than taken from the PBF header: Geofabrik's headers describe the cut
        # rectangle, which for England overhangs into Wales and the sea. What the app needs to know
        # is where there is actually data.
        self.bounds = None

    def note(self, lat, lon):
        if self.bounds is None:
            self.bounds = [lat, lat, lon, lon]
            return
        self.bounds[0] = min(self.bounds[0], lat)
        self.bounds[1] = max(self.bounds[1], lat)
        self.bounds[2] = min(self.bounds[2], lon)
        self.bounds[3] = max(self.bounds[3], lon)

    def flush(self):
        if self.roads:
            # The bounding box goes to the R-tree and *only* there. Storing it on the row as well
            # duplicated four REALs across 4.3 million rows for no reader — the candidate query
            # joins through the index and never selects them — which is about 140 MB.
            self.db.executemany(
                "INSERT OR IGNORE INTO road (id, name, ref, class, mph, geom, lit,"
                " lanes, oneway, turn_fwd, turn_back)"
                " VALUES (?,?,?,?,?,?,?,?,?,?,?)",
                [(r[0], r[1], r[2], r[3], r[4], r[9], r[10], r[11], r[12], r[13], r[14])
                 for r in self.roads])
            self.db.executemany(
                "INSERT OR IGNORE INTO road_bbox (id, minlat, maxlat, minlon, maxlon)"
                " VALUES (?,?,?,?,?)",
                [(r[0], r[5], r[6], r[7], r[8]) for r in self.roads])
            self.roads.clear()
        if self.cameras:
            self.db.executemany(
                "INSERT OR IGNORE INTO camera (id, kind, mph, direction, lat, lon) VALUES (?,?,?,?,?,?)",
                self.cameras)
            self.cameras.clear()
        if self.stations:
            self.db.executemany(
                "INSERT OR IGNORE INTO station (id, name, brand, lat, lon) VALUES (?,?,?,?,?)",
                self.stations)
            self.stations.clear()
        self.db.commit()

    def node(self, n):
        if n.id in self.wanted_nodes:
            self.located[("n", n.id)] = (n.location.lat, n.location.lon)
        tags = dict(n.tags)
        kind = camera_kind(tags)
        if kind:
            self.cameras.append((n.id, kind, parse_mph(tags.get("maxspeed")),
                                 parse_direction(tags.get("direction")),
                                 n.location.lat, n.location.lon))
        elif tags.get("amenity") == "fuel":
            self.stations.append((n.id, tags.get("name"), tags.get("brand") or tags.get("operator"),
                                  n.location.lat, n.location.lon))

    def way(self, w):
        self.seen += 1
        if self.seen % 2_000_000 == 0:
            print(f"  {self.seen:,} ways in {time.time()-self.started:.0f}s", flush=True)

        if w.id in self.wanted_ways:
            # The way's **first** point, which is what Overpass's `out geom` hands the online path,
            # so the offline and online answers agree rather than differing by which end of a
            # segment they happened to pick.
            try:
                first = next((n for n in w.nodes if n.location.valid()), None)
                if first is not None:
                    self.located[("w", w.id)] = (first.lat, first.lon)
            except osmium.InvalidLocationError:
                pass

        tags = dict(w.tags)

        # Gantries are occasionally mapped as ways rather than nodes. Rare, but a missed camera is
        # the one failure this whole feature exists to prevent.
        kind = camera_kind(tags)
        if kind:
            try:
                first = next((n for n in w.nodes if n.location.valid()), None)
            except osmium.InvalidLocationError:
                first = None
            if first is not None:
                # Negative id, so a way-camera can never collide with a node-camera of the same
                # number. OSM ids are only unique within an element type.
                self.cameras.append((-w.id, kind, parse_mph(tags.get("maxspeed")),
                                     parse_direction(tags.get("direction")),
                                     first.lat, first.lon))

        highway = tags.get("highway")
        if highway not in RIDEABLE or highway in SKIP:
            return
        try:
            coords = [(n.lat, n.lon) for n in w.nodes if n.location.valid()]
        except osmium.InvalidLocationError:
            return
        if len(coords) < 2:
            return
        lats = [c[0] for c in coords]
        lons = [c[1] for c in coords]
        self.note(min(lats), min(lons))
        self.note(max(lats), max(lons))
        # Any lit value except an explicit negative means lamps: yes, 24/7, automatic,
        # sunset-sunrise all describe lighting that exists.
        lit_tag = tags.get("lit")
        lit = None if lit_tag is None else (0 if lit_tag in ("no", "disused") else 1)
        # Lane guidance (v6). On a oneway carriageway — where exit-only lanes actually happen —
        # the tag is plain `turn:lanes`; on a two-way road each direction gets its own suffix.
        # Both are kept verbatim: the pipe-and-semicolon grammar is parsed once, in Swift, where
        # it has tests, rather than half-parsed here and half there.
        oneway = parse_oneway(tags.get("oneway"))
        turn_fwd = tags.get("turn:lanes:forward") or (tags.get("turn:lanes") if oneway != 0 else None)
        turn_back = tags.get("turn:lanes:backward")
        self.roads.append((
            w.id, tags.get("name"), tags.get("ref"), CLASS_ID[highway],
            parse_mph(tags.get("maxspeed")),
            min(lats), max(lats), min(lons), max(lons), pack(coords), lit,
            parse_lanes(tags.get("lanes")), oneway, turn_fwd, turn_back,
        ))
        if len(self.roads) >= 50_000:
            self.flush()


def attach_roads(db):
    """Give every camera the road it stands beside, and where along it.

    Three facts settle whether a camera is about *this* rider: which road it is on, where on that
    road, and which way it faces. The first two are properties of the map and belong here, computed
    once, rather than re-derived from geometry on every GPS fix. Straight-line distance cannot do
    it: six cameras on the M1 slip roads were announced to a rider on the A1081 beside them —
    thirty metres apart in space, several hundred by road.

    Nearest road by bounding box, then by true perpendicular distance to its segments — the same
    measure the app uses to decide which road the *rider* is on, so the two answers are comparable.
    Further than 40 m from anything and the camera is left unattached rather than guessed at.
    """
    def unpack(blob):
        return [(struct.unpack_from("<i", blob, i)[0] / 1e7,
                 struct.unpack_from("<i", blob, i + 4)[0] / 1e7)
                for i in range(0, len(blob), 8)]

    def segment_distance(point, a, b):
        scale = math.cos(math.radians(a[0]))
        bx, by = (b[1] - a[1]) * 111_320 * scale, (b[0] - a[0]) * 111_320
        px, py = (point[1] - a[1]) * 111_320 * scale, (point[0] - a[0]) * 111_320
        length = bx * bx + by * by
        if length == 0:
            return math.hypot(px, py), 0.0
        t = max(0.0, min(1.0, (px * bx + py * by) / length))
        return math.hypot(px - t * bx, py - t * by), t * math.sqrt(length)

    cameras = db.execute("SELECT id, lat, lon FROM camera").fetchall()
    updates = []
    for cid, lat, lon in cameras:
        pad = 60 / 111_320
        lonpad = pad / math.cos(math.radians(lat))
        best = None
        for rid, name, ref, cls, geom in db.execute(
            "SELECT r.id, r.name, r.ref, r.class, r.geom FROM road_bbox b JOIN road r ON r.id = b.id"
            " WHERE b.maxlat >= ? AND b.minlat <= ? AND b.maxlon >= ? AND b.minlon <= ?",
            (lat - pad, lat + pad, lon - lonpad, lon + lonpad),
        ):
            points = unpack(geom)
            travelled = 0.0
            for i in range(len(points) - 1):
                a, b = points[i], points[i + 1]
                offset, into = segment_distance((lat, lon), a, b)
                if best is None or offset < best[0]:
                    best = (offset, rid, name, ref, cls, travelled + into)
                travelled += math.hypot(
                    (b[0] - a[0]) * 111_320,
                    (b[1] - a[1]) * 111_320 * math.cos(math.radians(a[0])))
        if best and best[0] <= 40:
            updates.append((best[1], best[2], best[3], best[4], best[5], cid))
    db.executemany(
        "UPDATE camera SET road_id=?, road_name=?, road_ref=?, road_class=?, road_offset=?"
        " WHERE id=?", updates)
    db.execute("CREATE INDEX camera_road ON camera(road_id)")
    db.commit()
    print(f"  cameras attached to a road: {len(updates):,}/{len(cameras):,}", flush=True)


def zone_rows(zones, located):
    """Zone rows with their geometry filled in from the located members.

    A member that resolves to nothing leaves its end NULL, and that is deliberately not papered
    over: the app treats an absent start as "fall back to the first average camera" and an absent
    end as "never exit on geometry alone", both of which are honest. Inventing a boundary would
    announce the end of a check the rider is still inside.

    Matches `parseAverageZones` in SpeedCamera.swift exactly — `from` and `to` only, no device
    fallback here, because the device fallback belongs to `averageZoneEntered` where it can see
    the cameras actually in range.
    """
    for zone_id, (mph, roles) in zones.items():
        start = located.get(roles.get("from"))
        end = located.get(roles.get("to"))
        yield (zone_id, mph,
               start[0] if start else None, start[1] if start else None,
               end[0] if end else None, end[1] if end else None)


def main(pbf, out):
    db = sqlite3.connect(out)
    db.executescript("""
        PRAGMA journal_mode=OFF; PRAGMA synchronous=OFF;
        -- lit: 1 has street lamps, 0 tagged as not having them, NULL untagged. In the UK this is
        -- the law's own discriminator: lamps and no signs make a *restricted road*, 30 mph
        -- whatever the class - the difference between the A505 through Dunstable and the same
        -- A505 in the fields, neither of which carries a maxspeed tag.
        -- Lane guidance (v6): lanes is the tagged total, oneway is 1/-1/0/NULL as parse_oneway
        -- says, and turn_fwd/turn_back hold the raw turn:lanes strings for travel with and
        -- against the geometry. Tagged on a few percent of ways - motorways and big junction
        -- approaches - and NULL elsewhere, which is the app's cue to stay silent.
        CREATE TABLE road (id INTEGER PRIMARY KEY, name TEXT, ref TEXT, class INTEGER, mph INTEGER,
                           geom BLOB, lit INTEGER,
                           lanes INTEGER, oneway INTEGER, turn_fwd TEXT, turn_back TEXT);
        CREATE VIRTUAL TABLE road_bbox USING rtree(id, minlat, maxlat, minlon, maxlon);
        -- A camera belongs to a *road*, and which road it is on is a fact about the map rather
        -- than about the rider — so it is settled here, once, instead of re-derived from geometry
        -- on every GPS fix. Six cameras on the M1 slip roads were announced to a rider on the
        -- A1081 beside them because straight-line distance cannot tell a slip road from the
        -- carriageway it runs along: 30 m apart in space, several hundred by road.
        CREATE TABLE camera (id INTEGER PRIMARY KEY, kind TEXT, mph INTEGER, direction REAL,
                             lat REAL, lon REAL,
                             road_id INTEGER, road_name TEXT, road_ref TEXT, road_class INTEGER,
                             road_offset REAL);
        CREATE TABLE zone (id INTEGER PRIMARY KEY, mph INTEGER,
                           start_lat REAL, start_lon REAL, end_lat REAL, end_lon REAL);
        CREATE TABLE zone_device (zone_id INTEGER, lat REAL, lon REAL);
        CREATE TABLE station (id INTEGER PRIMARY KEY, name TEXT, brand TEXT, lat REAL, lon REAL);
        CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);
    """)
    print(f"scanning relations in {pbf} …", flush=True)
    scan = RelationScan()
    reader = osmium.io.Reader(pbf, osmium.osm.osm_entity_bits.RELATION)
    osmium.apply(reader, scan)
    reader.close()
    print(f"  {len(scan.zones):,} enforcement relations, "
          f"{len(scan.nodes):,} node and {len(scan.ways):,} way members to locate", flush=True)

    handler = Extractor(db, wanted_nodes=scan.nodes, wanted_ways=scan.ways)
    print(f"reading {pbf} …", flush=True)
    handler.apply_file(pbf, locations=True, idx="flex_mem")
    handler.flush()

    print("resolving zone geometry …", flush=True)
    db.executemany(
        "INSERT OR IGNORE INTO zone (id, mph, start_lat, start_lon, end_lat, end_lon)"
        " VALUES (?,?,?,?,?,?)", zone_rows(scan.zones, handler.located))
    db.commit()

    db.executemany(
        "INSERT INTO zone_device (zone_id, lat, lon) VALUES (?,?,?)",
        [(zone_id, position[0], position[1])
         for zone_id, refs in scan.devices.items()
         for position in [handler.located.get(("n", ref)) for ref in refs]
         if position is not None])
    db.execute("CREATE INDEX zone_device_zone ON zone_device(zone_id)")
    db.commit()

    print("attaching cameras to roads …", flush=True)
    attach_roads(db)

    print("building spatial index …", flush=True)
    db.executescript("""
        CREATE VIRTUAL TABLE camera_bbox USING rtree(id, minlat, maxlat, minlon, maxlon);
        INSERT INTO camera_bbox SELECT id, lat, lat, lon, lon FROM camera;
        CREATE VIRTUAL TABLE station_bbox USING rtree(id, minlat, maxlat, minlon, maxlon);
        INSERT INTO station_bbox SELECT id, lat, lat, lon, lon FROM station;
        CREATE INDEX road_name ON road(name);
        CREATE INDEX zone_start ON zone(start_lat, start_lon);
    """)

    minlat, maxlat, minlon, maxlon = handler.bounds
    db.executemany("INSERT INTO meta (key, value) VALUES (?,?)", [
        ("minlat", str(minlat)), ("maxlat", str(maxlat)),
        ("minlon", str(minlon)), ("maxlon", str(maxlon)),
        ("source", pbf.rsplit("/", 1)[-1]),
        ("generated", time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())),
    ])
    db.commit()

    for table in ("road", "camera", "zone", "station"):
        print(f"  {table}: {db.execute(f'SELECT COUNT(*) FROM {table}').fetchone()[0]:,}", flush=True)
    laned = db.execute(
        "SELECT COUNT(*) FROM road WHERE turn_fwd IS NOT NULL OR turn_back IS NOT NULL"
    ).fetchone()[0]
    print(f"  roads with turn lanes: {laned:,}", flush=True)
    devices = db.execute("SELECT COUNT(DISTINCT zone_id) FROM zone_device").fetchone()[0]
    print(f"  zones with located devices: {devices:,}", flush=True)
    located = db.execute("SELECT COUNT(*) FROM zone WHERE start_lat IS NOT NULL").fetchone()[0]
    ended = db.execute("SELECT COUNT(*) FROM zone WHERE end_lat IS NOT NULL").fetchone()[0]
    total = db.execute("SELECT COUNT(*) FROM zone").fetchone()[0]
    print(f"  zones with a start: {located:,}/{total:,}   with an end: {ended:,}/{total:,}", flush=True)
    print(f"  bounds: {minlat:.4f}..{maxlat:.4f}, {minlon:.4f}..{maxlon:.4f}", flush=True)

    db.execute("VACUUM")
    db.close()
    print("done", flush=True)


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
