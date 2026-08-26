## tests/test_map.nim — the station.
##
## `data/maps/vault.txt` is the SPECIFICATION, not an illustration, so every
## claim the design note makes about it is asserted here.

import std/[sets]
import hidden_agenda/[sim_types, station, sim_state]

template check(condition: bool, message: string) =
  ## A TEMPLATE, not a proc: the message is only built when the check fails.
  ## Eagerly concatenating a per-tick label across a 192-episode sweep is a
  ## minute of string building for nothing.
  if not condition:
    echo "FAIL: ", message
    quit(1)

block dimensions:
  let rows = gridLines()
  check(rows.len == MapRows, "vault.txt must be " & $MapRows & " rows")
  for row in rows:
    check(row.len == MapCols, "every row must be " & $MapCols & " wide")

block walkableAndReachable:
  let cells = walkableCells()
  check(cells.len == 249, "249 cells are walkable, got " & $cells.len)
  let field = grateField()
  for cell in cells:
    check(field.distAt(cell[0], cell[1]) < Unreachable,
      "cell " & $cell[0] & "," & $cell[1] & " is unreachable from the grate")

block seams:
  var seen = initHashSet[string]()
  for index, seam in SeamTable:
    check(tileAt(seam.x, seam.y) == tSeam,
      seam.id & " must sit on an S tile")
    check(not seen.containsOrIncl(seam.id), "seam ids must be distinct")
    check(seamAdjacentCells(index).len >= 1,
      seam.id & " needs at least one walkable orthogonal neighbour")
  ## The published walk distances, from the grate CENTRE (13, 9) to the
  ## nearest mining cell.
  let want = [17, 6, 17, 17, 6, 17]
  let fromCentre = cellField(GrateCx, GrateCy)
  for index in 0 ..< SeamTable.len:
    var best = Unreachable
    for cell in seamAdjacentCells(index):
      best = min(best, fromCentre.distAt(cell[0], cell[1]))
    check(best == want[index],
      SeamTable[index].id & " walk distance is " & $best & ", want " &
      $want[index])

block roomsAndDoorways:
  ## Each named room has EXACTLY ONE doorway, at the declared cell.
  for index, room in RoomTable:
    if room.id == "HUB":
      continue
    var inside = initHashSet[int]()
    for y in room.y0 .. room.y1:
      for x in room.x0 .. room.x1:
        if walkable(x, y):
          inside.incl(cellIndex(x, y))
    var exits = initHashSet[int]()
    for y in room.y0 .. room.y1:
      for x in room.x0 .. room.x1:
        if not walkable(x, y):
          continue
        for k in 0 .. 3:
          let
            nx = x + NeighbourDx[k]
            ny = y + NeighbourDy[k]
          if walkable(nx, ny) and cellIndex(nx, ny) notin inside:
            exits.incl(cellIndex(nx, ny))
    check(exits.len == 1,
      room.id & " must have exactly one doorway, has " & $exits.len)
    check(cellIndex(room.door[0], room.door[1]) in exits,
      room.id & "'s doorway must be the declared cell")

block roomRectangles:
  ## The room table's rectangles do not overlap and contain their seams.
  var claimed = initHashSet[int]()
  for room in RoomTable:
    for y in room.y0 .. room.y1:
      for x in room.x0 .. room.x1:
        check(not claimed.containsOrIncl(cellIndex(x, y)),
          "room rectangles overlap at " & $x & "," & $y)
  for seam in SeamTable:
    let index = roomIndex(seam.room)
    check(index >= 0, seam.id & " names a real room")
    let room = RoomTable[index]
    check(seam.x >= room.x0 and seam.x <= room.x1 and
      seam.y >= room.y0 and seam.y <= room.y1,
      seam.id & " must lie inside " & seam.room)

block grate:
  let cells = grateCells()
  check(cells.len == 9, "the grate is 3 x 3")
  for cell in cells:
    check(isGrate(cell[0], cell[1]), "every declared grate cell is a G tile")
    check(walkable(cell[0], cell[1]), "the grate is walkable")
  check(isGrate(GrateCx, GrateCy), "the grate centre is a grate cell")

block spawns:
  var seen = initHashSet[int]()
  for cell in SpawnCells:
    check(walkable(cell[0], cell[1]), "spawn cells are walkable")
    check(not seen.containsOrIncl(cellIndex(cell[0], cell[1])),
      "spawn cells are distinct")
  ## The spawn list rotates with `seed mod 5`, so no slot has a fixed cell.
  var cellsForSlotZero = initHashSet[int]()
  for seed in 0 .. 4:
    let rotation = spawnRotation(seed)
    let cell = SpawnCells[rotation mod Seats]
    cellsForSlotZero.incl(cellIndex(cell[0], cell[1]))
  check(cellsForSlotZero.len == Seats,
    "slot 0 must land on all five cells across five seeds")

block facing:
  ## Each cog spawns facing AWAY from the grate centre.
  check(spawnFacing(13, 7) == fN, "(13,7) faces north")
  check(spawnFacing(11, 11) == fS or spawnFacing(11, 11) == fW,
    "(11,11) faces out of the hub")
  check(facingToward(13, 9, 13, 2) == fN, "north of the grate is N")
  check(facingToward(13, 9, 24, 9) == fE, "east of the grate is E")
  check(facingToward(13, 9, 13, 16) == fS, "south of the grate is S")
  check(facingToward(13, 9, 2, 9) == fW, "west of the grate is W")

block corners:
  for index, room in RoomTable:
    for corner in roomCorners(index):
      check(walkable(corner[0], corner[1]),
        room.id & " patrol corners are walkable")
    let far = roomFarCorner(index)
    check(walkable(far[0], far[1]), room.id & " lurk corner is walkable")

echo "test_map: ok"
