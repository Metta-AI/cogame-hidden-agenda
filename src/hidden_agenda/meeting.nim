## The meeting machine: M1..M6, the one-shot conditional vote switch, and the
## exact tally rule.
##
## New module. Among Them's meeting -> chat -> simultaneous-vote -> ejection loop
## becomes this, including its "teleport everyone to the meeting button and
## restore afterwards" (`meetingHome`) behaviour, which is kept.

import std/[algorithm, tables]
import sim_types, sim_state

const
  MeetingSeats*: array[Seats, array[2, int]] = [
    [11, 8], [15, 8], [11, 10], [15, 10], [13, 11]
  ]

type
  Tally* = object
    counts*: Table[string, int]
    skips*: int

proc tallyOf*(votes: openArray[string], states: openArray[CogState]): Tally =
  ## Every ACTIVE seat casts exactly one vote (a seat whose reply failed casts
  ## `skip`); frozen and ejected seats cast nothing.
  result.counts = initTable[string, int]()
  for slot in 0 ..< Seats:
    if states[slot] != csActive:
      continue
    let vote = votes[slot]
    if vote.len == 0 or vote == "skip":
      result.skips.inc
    else:
      result.counts[vote] = result.counts.getOrDefault(vote) + 1

proc leader*(tally: Tally): tuple[alias: string, count: int, unique: bool] =
  ## The alias with the strictly highest count. `unique` is false on a tie or
  ## when nobody was named at all.
  var best = 0
  var names: seq[string]
  for alias, count in tally.counts:
    if count > best:
      best = count
      names = @[alias]
    elif count == best and count > 0:
      names.add(alias)
  names.sort()
  if best == 0:
    ("", 0, false)
  else:
    (names[0], best, names.len == 1)

proc conditionHolds*(tally: Tally, condition: string): bool =
  ## `X` is an alias: holds iff X is the UNIQUE cog with the strictly highest
  ## count. `X == "tie"`: holds iff no cog leads strictly (the all-`skip` case
  ## included).
  let top = tally.leader()
  if condition == "tie":
    not top.unique
  else:
    top.unique and top.alias == condition

proc resolveTally*(tally: Tally):
    tuple[target: string, outcome: string] =
  ## `m` = the highest count among aliases, `s` = the number of skips.
  let top = tally.leader()
  if top.count > tally.skips and top.unique:
    (top.alias, "plurality")
  elif top.count > tally.skips:
    ("", "tie")
  else:
    ("", "skip")

proc tallyJson*(tally: Tally): auto =
  ## A stable, sorted rendering of the tally for the replay and the chrome.
  var aliases: seq[string]
  for alias in tally.counts.keys:
    aliases.add(alias)
  aliases.sort()
  var rows: seq[(string, int)]
  for alias in aliases:
    rows.add((alias, tally.counts[alias]))
  rows

proc meetingSeatFor*(sim: Sim, slot: int): array[2, int] =
  ## The five fixed meeting seats around the grate, assigned among the ACTIVE
  ## seats by where each cog was STANDING when the meeting opened - sorted by
  ## (row, col), the same tie-break the BFS uses - so a cog walking in from the
  ## north takes a north seat.
  ##
  ## Deliberately NOT slot order. The decision batch is issued after the
  ## teleport, so a seat's plan is chosen from its MEETING SEAT: with a slot
  ## order, slot 0 would plan from (11,8) and slot 4 from (13,11) at every
  ## meeting of every episode, and the crew-win rate would depend on which slot
  ## drew the impostor (tests/test_feasibility.nim gate (f)).
  var order: seq[(int, int, int)]
  for other in 0 ..< Seats:
    if sim.cogs[other].state != csActive:
      continue
    order.add((sim.cogs[other].y, sim.cogs[other].x, other))
  order.sort()
  for index, entry in order:
    if entry[2] == slot:
      return MeetingSeats[min(index, MeetingSeats.high)]
  MeetingSeats[0]
