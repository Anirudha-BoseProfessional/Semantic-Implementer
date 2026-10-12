# Semantic Implementer

Adds stable semantic identifiers to Flutter widget trees so UI automation can
address them — in bulk across a folder, or one widget at a time.

It never changes logic. Every edit either adds an argument to a widget or wraps
the widget in a `SemanticHelper` node; the original expression is left exactly
as written.

## Setup

Standalone Dart package. It is never added as a dependency of the app it edits.

```
cd "C:\Users\AnirudhaUdupa\Downloads\semantic implementer"
dart pub get
```

The Dart SDK ships with Flutter, so there is nothing else to install.

## Two ways to use it

**A first pass over new code** — point it at a folder, it instruments
everything that needs it:

```
dart run bin/semantic_implementer.dart
Enter directory path: C:\path\to\your\feature
```

**A targeted fix** — QA says one widget is wrong. Address that widget alone:

```
dart run bin/semantic_implementer.dart --at=lib/features/filter_section.dart:214
```

`--at` bypasses the skip rules entirely: if someone has decided that widget
matters, the tool stops arguing and instruments it.

The line does not have to be where the widget starts. Point at wherever your
cursor is — an argument line in the middle of a multi-line widget is fine:

```dart
48  FusionFlatContainer(
49    width: 308,              // --at=…:49 finds the FusionFlatContainer
50    child: FusionAppText(…), // --at=…:50 finds the FusionAppText
51  ),
```

A widget starting on that exact line wins. Otherwise every widget spanning the
line is offered, innermost first, so you choose rather than the tool guessing.
Structural widgets — `Row`, `Padding`, `Expanded` — are never offered.

## What happens on a run

1. Scans the project for which widgets accept a semantic id argument and what
   `SemanticTypes` defines. Both counts are printed — check them.
2. Parses every `.dart` file and decides which widgets need an id.
3. Widgets carrying text name themselves. Others are asked about, one at a time.
4. Prints a numbered summary of every intended edit.
5. You apply, abort, or change individual rows.

Nothing is written until step 5. Always `--dry-run` a new area first.

## The two transformations

**Inline** — widget already has a semantic parameter, so add an argument:

```dart
FusionAppText(text: localization.volumeTitle)
→ FusionAppText(semanticId: 'volume_title', text: localization.volumeTitle)
```

**Wrap** — it doesn't, so surround it:

```dart
Checkbox(value: muted, onChanged: ...)
→ SemanticHelper.toggle(
    testId: SemanticHelper.createTestId(SemanticTypes.checkbox, 'mute'),
    value: muted,
    child: Checkbox(value: muted, onChanged: ...),
  )
```

Other helper parameters are filled from the widget's own arguments, copied
verbatim — `value` off a `Checkbox`, `isEnabled: false` from `onPressed: null`,
`label` from its text. Nothing is invented.

## The decision ladder

For each widget, first match wins:

1. Skip if not a widget — lowercase name, a value type (`EdgeInsets`,
   `BoxDecoration`), or `SemanticHelper` itself
2. Skip if it already has a `semanticId` / `semanticsId` / `testId`
3. Skip if already the `child:` of a `SemanticHelper` call
4. **Inline** if its constructor accepts a semantic parameter
5. **Wrap with a role** if it's a known interactive widget
6. **Wrap as a section** if it's the root of a build method
7. Otherwise skip

Step 6 walks *down* from each `build`/`_build*` return through transparent
widgets — `Row`, `Column`, `Padding`, `Expanded`, builder closures — to the
first meaningful widget. That's what separates a `Container` opening a panel
from a `Container` used as a 13px colour swatch.

It stops if the chain ends in a call to another `_build*` method (that method
instruments itself) or in an existing `SemanticHelper` call.

## Naming

Widgets with text name themselves: `localization.volumeTitle` → `volume_title`,
`Text('Mute')` → `mute`, and a `GestureDetector` borrows its child's text.

Widgets without text fall back to the enclosing `_build*` method name, then the
class name. Those are the ones you get asked about:

```
filter_section.dart:214
  GestureDetector  ->  SemanticHelper.button
  in _buildPanelHeader  .  class _FilterSectionState
  suggested: filter_panel_header
  name >
```

Enter accepts, typing replaces, `s` skips the widget, `q` accepts all
remaining. `--review` asks about *every* widget, including self-named ones.

Names are slugified and de-duplicated — a collision gets `_2`.

## The summary prompt

```
    1.     14  Container        SemanticHelper.container   volume_panel
    2.     18  FusionAppText    semanticId                 volume_title

What do you want to do?
  1  apply all the edits above
  2  cancel, change nothing
  3  rename one
  4  give one a value
  5  wrap one so it can carry a value
  6  take the id away from one
  7  leave one alone
  8  show the list again

>
```

Pick one number. Options 3 to 7 then ask which row, and anything else they need:

```
> 3
Which one? (1-53, or Enter to go back) > 12
  GestureDetector at line 214, currently "filter_panel_header"
  new name (Enter to keep) > select_all
```

Everything is picked from a list, so there is no syntax to get wrong. Option 4
offers only the fields that target actually accepts, which means it cannot write
an argument that fails to compile.

## Editing ids that already exist

`--edit-existing` lists every id already in the source as a renameable row.
Combined with the actions above, that covers the usual QA requests:

- **"This id is wrong"** → `--edit-existing`, then option 3
- **"This widget has no id"** → `--at=file.dart:214`
- **"Remove this id"** → `--edit-existing`, then option 6
- **"It needs a value too"** → see below

### Giving a widget a value it can't hold

`FusionAppText` accepts a `semanticId` but no `value`. To publish its text as a
semantic value, trade the inline id for a wrapper that can carry both:

Run with `--edit-existing`, then at the menu:

```
3  rename it           → pick the row → type onn_off
5  wrap it             → pick the row
4  give it a value     → pick the row → pick "value" → Enter reuses its text
1  apply
```

Pressing Enter at the value prompt uses the widget's own text. Result:

```dart
SemanticHelper.staticText(
  testId: SemanticHelper.createTestId(SemanticTypes.text, 'onn_off'),
  value: localization.onOff,
  child: FusionAppText(text: localization.onOff),
)
```

The inline `semanticId` is dropped so the id isn't duplicated in two places.

## Flags

| Flag | Effect |
|---|---|
| `--dry-run` | never writes; prints the summary and stops |
| `--auto` | take every suggestion, no prompts |
| `--review` / `--step` | ask about every widget, not just unnamed ones |
| `--edit-existing` | list ids already in the source as editable rows |
| `--at=<file>:<line>` | work on one widget, bypassing the skip rules |
| `--scan=<path>` | extra path to scan for widget definitions |
| `--no-format` | skip the `dart format` pass |

## Formatting

Wrapping inserts structurally correct but unindented code. The tool runs
`dart format` afterwards **only** when it finds `formatter: page_width:` in your
`analysis_options.yaml` — guessing the width would reflow every untouched line
and bury the real diff. If it's absent, format the changed files yourself.

## Idempotence and the name cache

Re-running is a no-op: widgets that already carry an id are skipped.

Names you type are cached in `.semantic_ids.json` in the target directory, keyed
by file and line, so an aborted run doesn't re-ask. Delete that file to start
naming fresh. It is written into the directory you target — don't commit it.

## Verifying changes to the tool

`test_fixture/` is the regression suite and is kept **uninstrumented on
purpose** — the tool proposing the right edits against it is the test.

```
dart analyze                                    # tool itself
dart analyze test_fixture                       # fixture compiles
dart run bin/semantic_implementer.dart --dry-run --auto \
  --scan=test_fixture/stubs test_fixture/input  # prints the edit count
```

Then copy `test_fixture/` elsewhere, apply there, and `dart analyze` the copy —
that's what catches a wrong parameter name, a missing required helper argument,
or broken `child:` nesting. Re-run on the copy to confirm zero edits.

`--scan=test_fixture/stubs` matters: without it `SemanticTypes` isn't found and
the tool silently falls back to `container`/`section`/`button`. The stubs live
outside the target on purpose — scanning them as the target would register
`Container` and `Row` as project-declared widgets and suppress all section-root
wrapping.
