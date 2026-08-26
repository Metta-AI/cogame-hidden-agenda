## The station: the one authored 27 x 19 map, its rooms, seams and grate, the
## BFS the kernels walk on, and `los()` / `visible()`.
##
## Heavily reduced fork of `coworld-ctf/src/ctf/arena.nim`: the terrain
## generator, mapSpec, symmetry machinery, pixel queries and the map pool are
## GONE — there is one authored map, committed as ASCII in `data/maps/vault.txt`
## and compiled in with `staticRead` so native, wasm and test builds all read
## the identical bytes. What is kept and adapted is the line-of-sight walk,
## because the witness mechanic rests on it.

import std/[algorithm, strutils, tables]
import sim_types

const
  MapText* = staticRead("../../data/maps/vault.txt")

type
  Tile* = enum
    tWall, tFloor, tGrate, tSeam

  Room* = object
    id*: string
    name*: string
    x0*, x1*, y0*, y1*: int
    door*: array[2, int]

  Seam* = object
    id*: string
    room*: string
    x*, y*: int

const
  RoomTable*: array[7, Room] = [
    Room(id: "NW", name: "NORTHWEST VAULT", x0: 1, x1: 7, y0: 1, y1: 5,
      door: [4, 6]),
    Room(id: "N", name: "NORTH GALLERY", x0: 10, x1: 16, y0: 1, y1: 4,
      door: [13, 5]),
    Room(id: "NE", name: "NORTHEAST VAULT", x0: 19, x1: 25, y0: 1, y1: 5,
      door: [22, 6]),
    Room(id: "SW", name: "SOUTHWEST VAULT", x0: 1, x1: 7, y0: 13, y1: 17,
      door: [4, 12]),
    Room(id: "S", name: "SOUTH GALLERY", x0: 10, x1: 16, y0: 14, y1: 17,
      door: [13, 13]),
    Room(id: "SE", name: "SOUTHEAST VAULT", x0: 19, x1: 25, y0: 13, y1: 17,
      door: [22, 12]),
    Room(id: "HUB", name: "THE GRATE", x0: 9, x1: 17, y0: 7, y1: 11,
      door: [13, 9])
  ]

  SeamTable*: array[6, Seam] = [
    Seam(id: "S1", room: "NW", x: 2, y: 2),
    Seam(id: "S2", room: "N", x: 13, y: 2),
    Seam(id: "S3", room: "NE", x: 24, y: 2),
    Seam(id: "S4", room: "SW", x: 2, y: 16),
    Seam(id: "S5", room: "S", x: 13, y: 16),
    Seam(id: "S6", room: "SE", x: 24, y: 16)
  ]

  GrateX0* = 12
  GrateX1* = 14
  GrateY0* = 8
  GrateY1* = 10
  GrateCx* = 13
  GrateCy* = 9

  SpawnCells*: array[Seats, array[2, int]] = [
    [13, 7], [9, 7], [17, 7], [9, 11], [17, 11]
  ]
    ## Five cells around the grate, no two of them within the freeze beam's
    ## reach: the closest pair is 4 apart against `freezeRange = 2`. The
    ## design note's table put two of them at Chebyshev 2, which let a
    ## `strike` impostor freeze a crewmate on TICK ONE - the certification
    ## fixture then ended in twenty-six ticks, a one-second replay that the
    ## viewer soak cannot play. The spawn list is still rotated by
    ## `seed mod 5`, so no slot has a fixed cell.

var
  gridRows: array[MapRows, string]
  tiles: array[MapRows * MapCols, Tile]
  gridLoaded = false

proc loadGrid() =
  if gridLoaded:
    return
  var row = 0
  for line in MapText.splitLines():
    let text = line.strip(leading = false, trailing = true)
    if text.len == 0:
      continue
    if row >= MapRows:
      raise newException(HiddenAgendaError, "vault.txt has too many rows")
    if text.len != MapCols:
      raise newException(HiddenAgendaError,
        "vault.txt row " & $row & " is " & $text.len & " wide, want " & $MapCols)
    gridRows[row] = text
    for col, ch in text:
      let tile =
        case ch
        of '#': tWall
        of '.': tFloor
        of 'G': tGrate
        of 'S': tSeam
        else:
          raise newException(HiddenAgendaError,
            "vault.txt has an unknown tile '" & $ch & "'")
      tiles[row * MapCols + col] = tile
    row.inc
  if row != MapRows:
    raise newException(HiddenAgendaError, "vault.txt has " & $row & " rows")
  gridLoaded = true

loadGrid()

proc gridLines*(): seq[string] =
  for row in gridRows:
    result.add(row)

proc inBounds*(x, y: int): bool =
  x >= 0 and x < MapCols and y >= 0 and y < MapRows

proc tileAt*(x, y: int): Tile =
  if not inBounds(x, y): tWall else: tiles[y * MapCols + x]

proc walkable*(x, y: int): bool =
  let t = tileAt(x, y)
  t == tFloor or t == tGrate

proc blocksSight*(x, y: int): bool =
  let t = tileAt(x, y)
  t == tWall or t == tSeam

proc isGrate*(x, y: int): bool =
  tileAt(x, y) == tGrate

proc cellIndex*(x, y: int): int = y * MapCols + x

proc grateCells*(): seq[array[2, int]] =
  for y in GrateY0 .. GrateY1:
    for x in GrateX0 .. GrateX1:
      result.add([x, y])

var walkableCache: seq[array[2, int]]

proc walkableCells*(): seq[array[2, int]] =
  ## Computed once: 249 cells on a map that never changes.
  if walkableCache.len == 0:
    for y in 0 ..< MapRows:
      for x in 0 ..< MapCols:
        if walkable(x, y):
          walkableCache.add([x, y])
  walkableCache

proc roomIndex*(id: string): int =
  for i, room in RoomTable:
    if room.id == id:
      return i
  -1

proc seamIndex*(id: string): int =
  for i, seam in SeamTable:
    if seam.id == id:
      return i
  -1

proc roomOf*(x, y: int): string =
  ## The room containing a cell, or "" for a corridor cell.
  for room in RoomTable:
    if x >= room.x0 and x <= room.x1 and y >= room.y0 and y <= room.y1 and
        walkable(x, y):
      return room.id
  ""

proc roomName*(id: string): string =
  let index = roomIndex(id)
  if index < 0: "THE CORRIDOR" else: RoomTable[index].name

proc chebyshev*(ax, ay, bx, by: int): int =
  max(abs(ax - bx), abs(ay - by))

proc los*(ax, ay, bx, by: int): bool =
  ## Supercover Bresenham from (ax,ay) to (bx,by): clear iff no `#` wall and no
  ## `S` seam lies strictly between the endpoints.
  ##
  ## The endpoints are put in a CANONICAL order first, so the predicate is
  ## symmetric on cells by construction rather than by hoping the walk happens
  ## to be reversible (tests/test_vision.nim asserts it).
  if ax == bx and ay == by:
    return true
  var x0 = ax
  var y0 = ay
  var x1 = bx
  var y1 = by
  if (ay, ax) > (by, bx):
    swap(x0, x1)
    swap(y0, y1)
  let
    dx = abs(x1 - x0)
    dy = abs(y1 - y0)
    sx = if x1 > x0: 1 else: -1
    sy = if y1 > y0: 1 else: -1
  var
    x = x0
    y = y0
    err = dx - dy
  while true:
    if err > 0:
      x += sx
      err -= 2 * dy
    elif err < 0:
      y += sy
      err += 2 * dx
    else:
      ## Exactly on the corner: the segment passes through the diagonal, so
      ## the supercover takes both cells. Test them, then step diagonally.
      if not (x + sx == x1 and y == y1) and blocksSight(x + sx, y):
        return false
      if not (x == x1 and y + sy == y1) and blocksSight(x, y + sy):
        return false
      x += sx
      y += sy
      err += 2 * dx - 2 * dy
    if x == x1 and y == y1:
      return true
    if blocksSight(x, y):
      return false

# ---------------------------------------------------------------------------
# BFS. Neighbour expansion is always N, E, S, W, over walkable cells only.
# Other cogs are NOT obstacles for path PLANNING (only for the move itself),
# so a path is a pure function of the map and the target set.
# ---------------------------------------------------------------------------

const
  Unreachable* = 1_000_000
  NeighbourDx*: array[4, int] = [0, 1, 0, -1]
  NeighbourDy*: array[4, int] = [-1, 0, 1, 0]

type
  DistField* = object
    d*: array[MapRows * MapCols, int]

proc distFrom*(targets: openArray[array[2, int]]): DistField =
  for i in 0 ..< result.d.len:
    result.d[i] = Unreachable
  var queue: seq[int]
  for cell in targets:
    if not walkable(cell[0], cell[1]):
      continue
    let index = cellIndex(cell[0], cell[1])
    if result.d[index] != 0:
      result.d[index] = 0
      queue.add(index)
  var head = 0
  while head < queue.len:
    let index = queue[head]
    head.inc
    let
      x = index mod MapCols
      y = index div MapCols
    for k in 0 .. 3:
      let
        nx = x + NeighbourDx[k]
        ny = y + NeighbourDy[k]
      if not walkable(nx, ny):
        continue
      let ni = cellIndex(nx, ny)
      if result.d[ni] > result.d[index] + 1:
        result.d[ni] = result.d[index] + 1
        queue.add(ni)

proc distAt*(field: DistField, x, y: int): int =
  if not inBounds(x, y): Unreachable else: field.d[cellIndex(x, y)]

proc stepToward*(field: DistField, x, y: int): Action =
  ## One step down the distance field, neighbours tried N, E, S, W. `aWait`
  ## when already there or when no neighbour is closer.
  let here = field.distAt(x, y)
  if here <= 0 or here >= Unreachable:
    return aWait
  for k in 0 .. 3:
    let
      nx = x + NeighbourDx[k]
      ny = y + NeighbourDy[k]
    if walkable(nx, ny) and field.distAt(nx, ny) == here - 1:
      return moveActionFor(NeighbourDx[k], NeighbourDy[k])
  aWait

proc stepToward*(field: DistField, x, y: int,
    occupied: openArray[bool]): Action =
  ## The same step, but choosing among EQUALLY-OPTIMAL neighbours by occupancy,
  ## and side-stepping when the only closer neighbour is taken.
  ##
  ## The BFS field is untouched — other cogs are still not obstacles for path
  ## PLANNING, exactly as the design pins. What this adds is that when several
  ## neighbours are equally close the kernel takes a free one, and when the one
  ## closer neighbour is standing under somebody it steps sideways rather than
  ## waiting. Without it a single cog idling on the grate (a `guard` step, a
  ## finished `deposit`) wedges the whole crew behind it for a
  ## two-hundred-tick plan, and the station gridlocks.
  let here = field.distAt(x, y)
  if here <= 0 or here >= Unreachable:
    return aWait
  template freeAt(nx, ny: int): bool =
    walkable(nx, ny) and not occupied[cellIndex(nx, ny)]
  ## 1. A closer neighbour that is free. Several neighbours can be equally
  ##    close; taking a free one is not a different path length.
  for k in 0 .. 3:
    let
      nx = x + NeighbourDx[k]
      ny = y + NeighbourDy[k]
    if freeAt(nx, ny) and field.distAt(nx, ny) == here - 1:
      return moveActionFor(NeighbourDx[k], NeighbourDy[k])
  ## 2. Nothing closer is free: step SIDEWAYS around whoever is parked there,
  ##    if the room is wide enough to go round.
  for k in 0 .. 3:
    let
      nx = x + NeighbourDx[k]
      ny = y + NeighbourDy[k]
    if freeAt(nx, ny) and field.distAt(nx, ny) == here:
      return moveActionFor(NeighbourDx[k], NeighbourDy[k])
  ## 3. A one-wide corridor: keep the intent anyway and QUEUE. Step 7 of the
  ##    tick resolves the whole queue in one pass and swaps two cogs that are
  ##    stepping into each other's cell, so a corridor clears instead of
  ##    wedging. Dropping the intent here is what leaves a crewmate waiting
  ##    behind a stationary cog until its next decision point.
  for k in 0 .. 3:
    let
      nx = x + NeighbourDx[k]
      ny = y + NeighbourDy[k]
    if walkable(nx, ny) and field.distAt(nx, ny) == here - 1:
      return moveActionFor(NeighbourDx[k], NeighbourDy[k])
  aWait

var
  grateFieldCache: DistField
  grateFieldReady = false
  seamFieldCache: array[6, DistField]
  seamFieldReady: array[6, bool]
  cellFieldCache = initTable[int, DistField]()

proc grateField*(): DistField =
  if not grateFieldReady:
    grateFieldCache = distFrom(grateCells())
    grateFieldReady = true
  grateFieldCache

proc seamAdjacentCells*(index: int): seq[array[2, int]] =
  let seam = SeamTable[index]
  for k in 0 .. 3:
    let
      nx = seam.x + NeighbourDx[k]
      ny = seam.y + NeighbourDy[k]
    if walkable(nx, ny):
      result.add([nx, ny])

proc seamField*(index: int): DistField =
  if not seamFieldReady[index]:
    seamFieldCache[index] = distFrom(seamAdjacentCells(index))
    seamFieldReady[index] = true
  seamFieldCache[index]

proc cellField*(x, y: int): DistField =
  ## Distance field to one cell, memoised: 249 possible fields at most, and the
  ## kernels ask for the same handful every tick.
  let key = cellIndex(x, y)
  if cellFieldCache.hasKey(key):
    return cellFieldCache[key]
  let field = distFrom([[x, y]])
  cellFieldCache[key] = field
  field

proc walkDistance*(ax, ay, bx, by: int): int =
  cellField(bx, by).distAt(ax, ay)

proc walkableNeighbours*(x, y: int): int =
  for k in 0 .. 3:
    if walkable(x + NeighbourDx[k], y + NeighbourDy[k]):
      result.inc

proc isChokepoint*(x, y: int): bool =
  ## A doorway or a one-wide corridor cell. Nothing that merely WAITS may park
  ## on one: a single idle cog in a one-wide corridor wedges the whole crew
  ## behind it until its next decision point.
  walkable(x, y) and walkableNeighbours(x, y) <= 2

proc adjacentSeam*(x, y: int): int =
  ## The seam index orthogonally adjacent to a cell, -1 when there is none.
  ## S1..S6 order, so a cell touching two seams (there is none on this map)
  ## would resolve deterministically.
  for i, seam in SeamTable:
    if abs(seam.x - x) + abs(seam.y - y) == 1:
      return i
  -1

var
  cornerCache: array[7, array[4, array[2, int]]]
  cornerReady: array[7, bool]
  farCache: array[7, array[2, int]]
  farReady: array[7, bool]

proc computeRoomCorners(index: int): array[4, array[2, int]] =
  ## Four patrol waypoints for a room: the walkable interior cell nearest each
  ## rectangle corner, in NW, NE, SE, SW order.
  let room = RoomTable[index]
  let anchors = [
    [room.x0, room.y0], [room.x1, room.y0],
    [room.x1, room.y1], [room.x0, room.y1]
  ]
  for i, anchor in anchors:
    var best = [room.door[0], room.door[1]]
    var bestScore = high(int)
    for y in room.y0 .. room.y1:
      for x in room.x0 .. room.x1:
        if not walkable(x, y):
          continue
        let score = abs(x - anchor[0]) + abs(y - anchor[1])
        if score < bestScore:
          bestScore = score
          best = [x, y]
    result[i] = best

proc roomCorners*(index: int): array[4, array[2, int]] =
  if not cornerReady[index]:
    cornerCache[index] = computeRoomCorners(index)
    cornerReady[index] = true
  cornerCache[index]

proc computeRoomFarCorner(index: int): array[2, int] =
  ## The walkable interior cell furthest (by walk distance) from the room's
  ## doorway; ties by (row, col) ascending. Where `lurk` waits.
  let room = RoomTable[index]
  let field = cellField(room.door[0], room.door[1])
  var best = [room.door[0], room.door[1]]
  var bestDist = -1
  for y in room.y0 .. room.y1:
    for x in room.x0 .. room.x1:
      if not walkable(x, y):
        continue
      let d = field.distAt(x, y)
      if d >= Unreachable:
        continue
      if d > bestDist:
        bestDist = d
        best = [x, y]
  best

proc roomFarCorner*(index: int): array[2, int] =
  if not farReady[index]:
    farCache[index] = computeRoomFarCorner(index)
    farReady[index] = true
  farCache[index]

proc quadrantOf*(facing: Facing, dx, dy: int): bool =
  ## Whether the offset lies in the 90-degree wedge on `facing`.
  case facing
  of fN: dy < 0 and abs(dx) <= -dy
  of fS: dy > 0 and abs(dx) <= dy
  of fE: dx > 0 and abs(dy) <= dx
  of fW: dx < 0 and abs(dy) <= -dx

proc facingToward*(fromX, fromY, toX, toY: int): Facing =
  ## The quadrant containing the vector; exact ties resolve to N. Used for
  ## spawn facing, `watch`, `lurk`, `mine` and `deposit` facing rules.
  let
    dx = toX - fromX
    dy = toY - fromY
  if dx == 0 and dy == 0:
    return fN
  for f in [fN, fE, fS, fW]:
    if quadrantOf(f, dx, dy):
      return f
  ## Exactly on a diagonal boundary the wedge test above already accepts two
  ## quadrants and returns the first, so this is unreachable; keep it total.
  fN

proc spawnFacing*(x, y: int): Facing =
  ## Facing AWAY from the grate centre: the quadrant containing the vector from
  ## (GrateCx, GrateCy) to the spawn cell, exact ties resolving to N.
  facingToward(GrateCx, GrateCy, x, y)

proc sortedRoomIds*(): seq[string] =
  for room in RoomTable:
    result.add(room.id)
  result.sort()
