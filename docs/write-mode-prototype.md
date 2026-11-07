# Magistris Write mode prototype

Write mode converts handwritten Apple Pencil notes and rests in one empty bar into editable MuseScore notation. The ink stays available for correction while the engraved preview is being reviewed. Conversion is one undoable edit.

## Using the prototype

1. Open a score in Edit mode and select an empty bar on a treble or bass staff.
2. Choose the voice, then tap Write. Draw inside the highlighted bar with Apple Pencil.
3. Review the recognized events and rhythm tally. Use Undo Ink or Clear to correct strokes.
4. Request the engraved preview. Any remaining beats are shown as rests.
5. Tap Convert to insert the previewed notation. The normal score Undo restores the previous bar.

The prototype processes one staff and one voice at a time. Its supported vocabulary and uncertainty messages are defined by the original recognizer in `MuseReaderiOS/MuseReaderiOS/Models/Handwriting/MusicInkRecognizer.swift`. Unrecognized or ambiguous strokes stay available for correction. Existing musical content requires a separate editing workflow. Changes to the score, part, page or layout invalidate a pending writing target.

Draw an open oval for a whole note and add one stem for a half note. Fill the oval, or draw a short diagonal head, for a quarter note. Add one curved flag for an eighth note. Heads and stems may be separate strokes or one continuous stroke. One or two dots to the right extend the duration.

For rests, draw a rectangular block hanging from the second staff line for a whole rest, or sitting on the middle line for a half rest. Draw a zigzag with a lower hook for a quarter rest. An eighth rest uses a small loop followed by a slanted descending tail in one stroke.

Beamed notes, chords, handwritten accidentals, ties, tuplets, and percussion handwriting are outside this prototype. Use the existing editor for those symbols. Geometric recognition has not yet been measured on handwriting from independent writers; the preview remains essential.

## Score compatibility

The native MuseScore 4.7.6 engine determines pitch from staff position, clef and key. It validates the bar and inserts the confirmed events at explicit rhythmic positions. Preview uses a temporary score, and conversion uses a single native undo command with rollback on error.

Save the result as MSCZ, reopen it in Magistris, and open it in desktop MuseScore Studio 4.7.6. Check pitches, durations, rests, Undo and Redo, and the linked part when present. The file format is MuseScore 4.70.

## Recognition and licensing

The handwritten-symbol recognizer is original Magistris code under the MIT license. It analyzes stroke geometry and staff context. Its standalone source depends on Foundation and carries no external model, training dataset, or vendor recognition SDK.

The MIT license permits reuse and commercial distribution of this module subject to its notice requirements. Magistris also incorporates the GPLv3 MuseScore engine and retains its distribution obligations as a combined application. GPL software can be distributed either without charge or for a fee. See [GNU's explanation of selling free software](https://www.gnu.org/philosophy/selling.en.html) and [its linking FAQ](https://www.gnu.org/licenses/gpl-faq.html.en#LinkingWithGPL).

The module's license appears beside its source and in the app's bundled `Magistris-Handwriting-MIT.txt` notice.

## Device acceptance

The standalone recognizer checks run in CI before the iPad archive. To run them locally from the repository root:

```sh
xcrun swiftc -swift-version 5 -default-isolation MainActor \
  -enable-upcoming-feature NonisolatedNonsendingByDefault \
  -module-cache-path /tmp/magistris-music-ink-cache \
  MuseReaderiOS/MuseReaderiOS/Models/Handwriting/MusicInkRecognizer.swift \
  MuseReaderiOS/Checks/MusicInkRecognizerChecks.swift \
  -o /tmp/magistris-music-ink-checks
/tmp/magistris-music-ink-checks
```

The native handwriting regressions run in `score_render_accidental_tests` with `ARIA_TEST_FILTER=handwriting`. They cover preview isolation, conversion, Undo/Redo, MSCZ reopening, late-event rollback, clef/key/voice mapping, linked parts, stale targets, and refusal of unsupported percussion staves. Set `ARIA_HANDWRITING_TEST_ARTIFACT_DIR` to preserve the converted MSCZ files and native PNG previews for desktop review.

Test with a physical Apple Pencil, including an iPad without hover support. Check fast successive strokes, separate notehead and stem strokes, rests, partial bars, ambiguous ink, panning and pinch zoom, rotation, split view, page changes, and score edits while a preview is pending. Confirm that Cancel preserves the score and that a successful Convert creates one Undo step.
