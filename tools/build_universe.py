#!/usr/bin/env python3
"""Rebuild src/map/universe.bin from CCP's static data, after a game update changes the map.

Usage: python tools/build_universe.py [sde.zip]

Without a zip it downloads the latest JSONL release. Run it by hand: the build never needs the network.
The layout is read by src/map/universe.zig; every number is a little-endian u16 unless noted.

  "EVEU"                      4 bytes
  system count, link count, region count, constellation count, largest region's system count
  name offsets                count + 1, into the names
  link offsets                count + 1, into the links
  links                       system indices, each system's neighbours in a run
  by id                       system indices, sorted by CCP's system ID
  region name offsets         region count + 1, into the names
  constellation name offsets  constellation count + 1, into the names
  region IDs                  u32 each, CCP's, which profiles save
  systems                     one 26-byte record each, in system index order
  names                       UTF-8 bytes, no separators: systems sorted ignoring case, then regions, then constellations

A system record is:

  CCP's system ID             u32
  x, y                        i16, CCP's flattened map in MAP_UNIT steps, y growing down the screen
  constellation               index
  region                      u8, an index
  security                    i8, in tenths as the game rounds it
  NPC stations, planets       u8 each
  position                    three f32, light years in true 3D space, for jump drive range
"""
import json
import math
import pathlib
import struct
import sys
import tempfile
import urllib.request
import zipfile

LATEST = "https://developers.eveonline.com/static-data/eve-online-static-data-latest-jsonl.zip"
OUTPUT = pathlib.Path(__file__).resolve().parents[1] / "src" / "map" / "universe.bin"
# Fine enough for the map's lattice, which is about 20 of these, and keeps New Eden inside an i16.
MAP_UNIT = 1e14
LIGHT_YEAR_METRES = 9.46e15


def rows(archive, name):
    with archive.open(name) as lines:
        for line in lines:
            yield json.loads(line)


def shown_security(security):
    """The game rounds to one place, but never rounds a positive system down to 0.0."""
    if 0 < security < 0.05:
        return 1
    return math.floor(security * 10 + 0.5)


def build(archive):
    systems = {row["_key"]: row for row in rows(archive, "mapSolarSystems.jsonl")}
    region_names = {row["_key"]: row["name"]["en"] for row in rows(archive, "mapRegions.jsonl")}
    constellation_names = {row["_key"]: row["name"]["en"] for row in rows(archive, "mapConstellations.jsonl")}
    links = {}
    for gate in rows(archive, "mapStargates.jsonl"):
        links.setdefault(gate["solarSystemID"], set()).add(gate["destination"]["solarSystemID"])
    stations = {}
    for station in rows(archive, "npcStations.jsonl"):
        stations[station["solarSystemID"]] = stations.get(station["solarSystemID"], 0) + 1

    ordered = sorted(links, key=lambda system: systems[system]["name"]["en"].lower())
    index_of = {system: index for index, system in enumerate(ordered)}
    regions = sorted({systems[system]["regionID"] for system in ordered}, key=lambda region: region_names[region].lower())
    region_index = {region: index for index, region in enumerate(regions)}
    constellations = sorted({systems[system]["constellationID"] for system in ordered})
    constellation_index = {constellation: index for index, constellation in enumerate(constellations)}

    name_offsets, link_offsets, link_indices, name_bytes = [], [], [], bytearray()
    records = bytearray()
    region_sizes = [0] * len(regions)
    for system in ordered:
        row = systems[system]
        name_offsets.append(len(name_bytes))
        link_offsets.append(len(link_indices))
        name_bytes += row["name"]["en"].encode("ascii")
        link_indices += sorted(index_of[neighbour] for neighbour in links[system])
        region_sizes[region_index[row["regionID"]]] += 1
        records += struct.pack(
            "<IhhHBbBBfff",
            system,
            round(row["position2D"]["x"] / MAP_UNIT),
            round(-row["position2D"]["y"] / MAP_UNIT),
            constellation_index[row["constellationID"]],
            region_index[row["regionID"]],
            shown_security(row["securityStatus"]),
            stations.get(system, 0),
            len(row.get("planetIDs", [])),
            row["position"]["x"] / LIGHT_YEAR_METRES,
            row["position"]["y"] / LIGHT_YEAR_METRES,
            row["position"]["z"] / LIGHT_YEAR_METRES,
        )
    name_offsets.append(len(name_bytes))
    link_offsets.append(len(link_indices))

    region_offsets = []
    for region in regions:
        region_offsets.append(len(name_bytes))
        name_bytes += region_names[region].encode("utf-8")
    region_offsets.append(len(name_bytes))
    constellation_offsets = []
    for constellation in constellations:
        constellation_offsets.append(len(name_bytes))
        name_bytes += constellation_names[constellation].encode("utf-8")
    constellation_offsets.append(len(name_bytes))
    if len(name_bytes) > 0xFFFF:
        raise ValueError(f"names no longer fit u16 offsets: {len(name_bytes)} bytes")

    count = len(ordered)
    by_id = [index_of[system] for system in sorted(ordered)]
    numbers = [
        count, len(link_indices), len(regions), len(constellations), max(region_sizes),
        *name_offsets, *link_offsets, *link_indices, *by_id, *region_offsets, *constellation_offsets,
    ]
    data = b"EVEU" + struct.pack(f"<{len(numbers)}H", *numbers) + struct.pack(f"<{len(regions)}I", *regions) + bytes(records) + bytes(name_bytes)
    return data, count, len(link_indices), len(regions), len(constellations)


def main():
    if len(sys.argv) > 1:
        source = pathlib.Path(sys.argv[1])
    else:
        source = pathlib.Path(tempfile.mkdtemp()) / "sde.zip"
        print(f"Downloading {LATEST}")
        urllib.request.urlretrieve(LATEST, source)

    with zipfile.ZipFile(source) as archive:
        data, system_count, link_count, region_count, constellation_count = build(archive)
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_bytes(data)
    print(f"Wrote {OUTPUT}: {system_count} systems, {link_count} links, {region_count} regions, {constellation_count} constellations, {len(data)} bytes")


if __name__ == "__main__":
    main()
