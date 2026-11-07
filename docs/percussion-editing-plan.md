# Percussion editing on iPad — implementation specification

Target format is MuseScore Studio 4.7.6 (MSCZ 4.70). This document records the design and acceptance criteria. See [iPadOS build and validation](aria-ipados-validation.md) for installation and device checks.

## Problem
The previous native note-entry path rejected non-standard staves. This blocked five-line drum kits and one-line unpitched percussion even when the score had a MuseScore drum mapping.

## Verified code paths
- `sandbox/engraving/score_render_edit_commands.cpp`: `insertNoteWithPitch` rejects `!isStandardStaff` before `Score::putNote`; `noteEntryPreview`, `enterRestAtCursor`, and keyboard note entry also have standard-staff guards.
- `MuseReaderiOS/MuseReaderiOS/Models/ScoreReaderStateEditing.swift`: Pencil taps call `LiveScoreRenderSession.insertNote`; finger taps in input mode currently select elements.
- Existing upstream-derived drum mapping: `src/engraving/dom/drumset.h` and `src/notationscene/qml/MuseScore/NotationScene/PercussionPanel.qml`.

## Proposed implementation
1. Identify unpitched staff types at the selected tick, without changing behavior for pitched or tablature staves.
2. Expose the instrument's valid drum pitches, names, voice, staff line and notehead through a read-only native bridge model. Do not hardcode GM drum numbers: respect per-instrument/custom mappings.
3. Provide an accessible touch-friendly percussion picker for the selected staff, with a sensible default for one-line percussion.
4. Add a native edit command taking a validated drum pitch and using MuseScore's own unpitched note-entry semantics. Maintain a single undo command, existing autosave and selection notifications.
5. Support rests, duration, deletion and undo/redo. Ensure preview uses the mapped notehead and staff position.
6. Reuse the shared Swift UI path where possible; verify Android behavior is unchanged.

## Acceptance tests
- Five-line kit: kick, snare, closed/open hi-hat, cymbal and tom; verify pitch, line, notehead and voice.
- One-line unpitched instrument: add, replace, delete notes and rests.
- Custom drumset mapping must survive edits; no fixed pitch-to-line assumption.
- Enter notes with touch and Apple Pencil; keyboard path does not regress.
- Undo/redo, autosave, reopen and MSCZ round-trip to MuseScore Studio 4.7.6.
- Existing pitched notation and tablature behavior unchanged.
- Verify both full score and extracted part if available.

## Engineering constraints
Follow `AGENTS.md` and `ONBOARDING.md`. Do not merge MuseScore upstream main (format 5.00). Run compatibility checks in `sandbox/engraving/compat/README.md` for any native-engine change. Do not claim device validation until tested on an iPad.

## Open technical question
Confirm which `Score::putNote`/note-input APIs already implement drumset mapping and how they determine the current drum pitch. Do not merely remove `isStandardStaff` guards without validating the resulting pitch, notehead and voice.
