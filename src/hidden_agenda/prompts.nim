## Game-owned wording selection. Kept outside simulation/replay configuration.
import std/[json, strutils]
import crunchy

type
  PromptVariant* = enum
    pvCanonical = "canonical"
    pvPlain = "plain"
    pvNumbered = "numbered"
    pvQuestions = "questions"
    pvReordered = "reordered"
    pvHeldoutBriefing = "heldout-briefing"
    pvHeldoutReference = "heldout-reference"
    pvMixed = "mixed"
  PromptSelection* = object
    variant*: PromptVariant
    seed*: int

const
  PromptBankVersion* = "hidden-agenda-rules-v3"

proc promptSelection*(node: JsonNode): PromptSelection =
  if node.kind != JObject:
    raise newException(ValueError, "prompt configuration must be an object")
  if node.hasKey("promptVariant"):
    if node["promptVariant"].kind != JString:
      raise newException(ValueError, "promptVariant must be a string")
    result.variant = parseEnum[PromptVariant](node["promptVariant"].getStr())
  if node.hasKey("promptSeed"):
    if node["promptSeed"].kind != JInt:
      raise newException(ValueError, "promptSeed must be an integer")
    result.seed = node["promptSeed"].getInt()
  if result.seed < 0:
    raise newException(ValueError, "promptSeed must be nonnegative")
  if result.variant == pvMixed and not node.hasKey("promptSeed"):
    raise newException(ValueError, "mixed wording requires an explicit promptSeed")

proc selectedVariant*(selection: PromptSelection): PromptVariant =
  if selection.variant == pvMixed: PromptVariant(selection.seed mod 5)
  else: selection.variant

proc promptMetadata*(selection: PromptSelection, system, user: string): JsonNode =
  %*{"bank": PromptBankVersion, "variant": $selection.selectedVariant,
    "selection": $selection.variant, "seed": selection.seed,
    "system_sha256": sha256(system).toHex, "user_sha256": sha256(user).toHex}

proc selectionMetadata*(selection: PromptSelection): JsonNode =
  %*{"bank": PromptBankVersion, "variant": $selection.selectedVariant,
    "selection": $selection.variant, "seed": selection.seed}

proc introduction*(selection: PromptSelection, identity: string): string =
  case selection.selectedVariant
  of pvCanonical: "You are " & identity & ", one of five cogs mining a sealed station. Four are CREW and exactly ONE is the IMPOSTOR. "
  of pvPlain: "You play " & identity & " among five cogs mining a sealed station. The group contains four CREW and exactly one IMPOSTOR. "
  of pvNumbered: "1. You are " & identity & ". 2. Five cogs mine a sealed station. 3. Four are CREW; exactly one is the IMPOSTOR. "
  of pvQuestions: "Who are you? " & identity & ". Where are you? A sealed station being mined by five cogs: four CREW and exactly one IMPOSTOR. "
  of pvReordered: "Four CREW and exactly one IMPOSTOR make up the five cogs mining a sealed station. You are " & identity & ". "
  of pvHeldoutBriefing: "Your identity is " & identity & ". You belong to a group of five cogs mining a sealed station, with four CREW and exactly one IMPOSTOR. "
  of pvHeldoutReference: "Identity: " & identity & ". Setting: mining a sealed station. Participants: five cogs, comprising four CREW and exactly one IMPOSTOR. "
  of pvMixed: raise newException(ValueError, "mixed must resolve")
