# Notice - lineage and prior art

This file records WoWClearance's design lineage honestly, so that any
future "they copied us" or "you copied them" claim has a record to refer
to. Originality is not claimed where a pattern is inherited or shared
with the broader WoW addon ecosystem.

---

## Lineage

WoWClearance is a fork of
[EbonClearance](https://github.com/powerfulqa/EbonClearance) by the same
author, ported from WoW 3.3.5a (Interface 30300) to WoW: Forever
(Interface 16001). The fork exists because Forever is a retail-lineage
client: the 3.3.5a API surface EbonClearance was written against is not
present there, so the port is a rewrite of the API layer rather than a
version bump.

This is a rename-and-port of the author's own work, not a fork of
someone else's. Copyright in both projects is held by the same person,
which is why the relicensing and rebranding in this repository did not
require anyone's permission.

What carried over: the gameplay loop, the decision core, the panel
architecture, the test suites, and the localization templates. What did
not: the Project Ebonhold affix and chance-on-hit subsystem, which is
specific to that private server and is disabled in this fork.

EbonClearance's own release history is in
[its changelog](https://github.com/powerfulqa/EbonClearance/blob/master/CHANGELOG.md). It describes EbonClearance,
not WoWClearance, and its version numbers, dates and feature claims belong
to that project. WoWClearance's own history is in
[`CHANGELOG.md`](CHANGELOG.md).

The design notes and plans behind the inherited features are in
[EbonClearance's `docs/`](https://github.com/powerfulqa/EbonClearance/tree/master/docs). They are not copied here.

---

## Inherited prior-art acknowledgements

EbonClearance's NOTICE.md acknowledged prior art in the WoW 3.3.5a
private-server auto-vendor niche: convergent feature shapes shared with
[AutoDelete](https://github.com/disarrayed/AutoDelete) and
[AutoLoot](https://github.com/Veronica-Vasilieva/AutoLoot), the
long-standing addon-message version-nudge pattern, the source-available
licence structure, and the `__<addon>_origin` / `__<addon>_author`
provenance-globals form.

Those acknowledgements are inherited here rather than restated as
WoWClearance's own. The full record, including the timeline and the
reciprocal credits between EbonClearance and AutoDelete, lives in
[EbonClearance's NOTICE.md](https://github.com/powerfulqa/EbonClearance/blob/master/NOTICE.md).
None of the competitive-timeline claims in that file are claims
WoWClearance makes about itself; WoWClearance ships in a different game
client and a different addon ecosystem.

Convergence on a similar shape is not, in itself, evidence of copying in
either direction. Verbatim code from another author's addon is not
present in this codebase.

---

## Community contributions

Credit recorded in EbonClearance carries forward to the code inherited
here.

**Ivo.** Ivo shared a personally-modified fork plus a small standalone
companion addon he wrote for his own use, and gave permission for the
patterns to be adapted back into upstream. Three features in this
codebase started from his work:

- **Affix-pipeline event log.** The `AffixDebugDump` structured event
  logger, its probe sites along the affix-decision pipeline, and the
  `/wc affixdebug` slash sub-command are adapted from his diagnostic
  prototype. (This feature belongs to the Project Ebonhold subsystem and
  is disabled in this fork; the credit stands regardless.)

- **"Already known by this character" tooltip annotation.** His
  companion addon detected already-learned tomes and recipes via a
  hidden tooltip scan. The underlying detection already existed
  upstream; his contribution is the idea of surfacing it as a
  user-visible cue independent of the protection toggles.

- **Item-level overlay on equippable gear slots.** Same idea and a
  similar rendering shape (quality-coloured text in the bottom-right
  corner, filtered by an equipLoc whitelist).

Thanks Ivo. His companion addon was treated as inspiration only; no code
from it was copied verbatim, and the implementations here were written
against Blizzard APIs.

---

## Source-available licence pattern

WoWClearance ships under a custom source-available attribution licence,
inherited from EbonClearance and restated for this fork. The structural
shape (Grant / Attribution / No-Rebrand / Forks / Bundling / No-Warranty
/ Termination / Severability) follows similar source-available licences
that have appeared in the WoW addon ecosystem before it. Neither project
claims the licence structure is original; it was adopted because it is
the right shape for the same anti-rebrand pressure other addons are
reacting to.

---

## Provenance globals pattern

WoWClearance writes the following globals at addon load:

```
WOWCLEARANCE_IDENT       = "WoWClearance"
WOWCLEARANCE_AUTHOR      = "Serv"
WOWCLEARANCE_ORIGIN      = "<canonical github url>"
__WoWClearance_origin    = "<canonical github url>"
__WoWClearance_author    = "Serv"
__WoWClearance_watermark = "<derived hex hash>"
```

The `__<addon>_origin` / `__<addon>_author` form (double-underscore
prefix, addon name, role suffix) is a pattern that appeared in other
addons before this one. WoWClearance does not claim the pattern is
original; it is deliberately compatible with something the broader scene
settled on for the same anti-rebrand reasons.

The `__WoWClearance_watermark` global and the export-string fingerprint
suffix (`;fp=<6 hex>`) follow EbonClearance's mechanism with a
WoWClearance-specific salt, so the two projects produce different
fingerprints for the same payload. See
[`docs/ADDON_GUIDE.md`](docs/ADDON_GUIDE.md) "Fingerprint and watermark"
for the convention and how to verify the value.

---

## The honest summary

- **Core gameplay loop**: inherited from EbonClearance, the same
  author's own prior work, with full public commit history in that
  repository.
- **Forever API port**: specific to this project.
- **Licence structure and provenance globals**: adopted patterns that
  exist elsewhere in the WoW addon ecosystem, acknowledged here, not
  original to either project.
- **Competitive-timeline claims**: none. Those in EbonClearance's NOTICE
  concern the 3.3.5a niche and are not restated here.

If you are reading this file in a derivative addon's source tree, that
addon is required by WoWClearance's [LICENSE](LICENSE) to preserve this
file in full and link to https://github.com/powerfulqa/WoWClearance.
