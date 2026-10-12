/// Adds semantic test identifiers to a directory of Flutter widget code.
///
/// Run it, type a directory, answer the prompts for widgets that carry no text
/// to name themselves, review the summary, then confirm the write.
library;

import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/features.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:path/path.dart' as p;
import 'package:semantic_implementer/naming.dart';
import 'package:semantic_implementer/rewriter.dart';
import 'package:semantic_implementer/rules.dart';
import 'package:semantic_implementer/widget_scan.dart';

const String _cacheFileName = '.semantic_ids.json';

void main(List<String> argv) {
  final _Options options = _Options.parse(argv);

  final _Spot? spot = options.at == null ? null : _Spot.parse(options.at!);
  if (options.at != null && spot == null) return;

  final String? target = _resolveTarget(spot?.directory ?? options.path);
  if (target == null) return;

  stdout.writeln('\nScanning project…');
  final ProjectFacts facts = scanProject(target, extraRoots: options.scanRoots);
  _reportFacts(facts);

  final List<File> files =
      spot == null ? _dartFilesIn(target) : <File>[File(spot.filePath)];
  if (files.isEmpty) {
    stdout.writeln('No .dart files found under $target');
    return;
  }
  stdout.writeln(
    spot == null
        ? 'Found ${files.length} .dart file(s).\n'
        : 'Targeting ${p.basename(spot.filePath)} line ${spot.line}.\n',
  );

  final IdRegistry registry = IdRegistry();
  final Map<String, List<Candidate>> byFile = <String, List<Candidate>>{};
  final Map<String, String> sources = <String, String>{};

  for (final File file in files) {
    final String source = file.readAsStringSync();
    final ParseStringResult parsed;
    try {
      parsed = parseString(
        content: source,
        featureSet: FeatureSet.latestLanguageVersion(),
        throwIfDiagnostics: false,
      );
    } on Object catch (e) {
      stderr.writeln('  skipped ${p.relative(file.path, from: target)}: $e');
      continue;
    }

    List<Candidate> found = analyzeUnit(
      filePath: file.path,
      unit: parsed.unit,
      lineInfo: parsed.lineInfo,
      facts: facts,
      registry: registry,
      includeExisting: options.editExisting || spot != null,
      forceLines: spot == null ? const <int>{} : <int>{spot.line},
    );
    if (spot != null) found = _narrowToSpot(found, spot.line);
    if (found.isNotEmpty) {
      byFile[file.path] = found;
      sources[file.path] = source;
    }
  }

  final int total = byFile.values.fold(0, (int a, List<Candidate> b) => a + b.length);
  if (total == 0) {
    stdout.writeln(
      spot == null
          ? 'Nothing to instrument — every widget already has an id.'
          : 'No widget found at ${p.basename(spot.filePath)}:${spot.line}.',
    );
    return;
  }

  final _NameCache cache = _NameCache.load(target);
  _nameAll(
    byFile,
    registry,
    cache,
    target,
    auto: options.auto,
    review: options.review && !options.auto,
  );
  cache.save(target);

  final Map<String, List<Candidate>> kept = <String, List<Candidate>>{};
  byFile.forEach((String path, List<Candidate> list) {
    final List<Candidate> live =
        list.where((Candidate c) => c.id != null).toList();
    if (live.isNotEmpty) kept[path] = live;
  });

  if (kept.isEmpty) {
    stdout.writeln('\nEvery candidate was skipped. Nothing written.');
    return;
  }

  final List<Candidate> ordered = _printSummary(kept, target);

  if (options.dryRun) {
    stdout.writeln('\nDry run — no files written.');
    return;
  }
  if (!_confirmOrEdit(ordered, registry, facts)) {
    stdout.writeln('Aborted. Nothing written.');
    return;
  }

  final List<String> written = <String>[];
  kept.forEach((String path, List<Candidate> list) {
    final String source = sources[path]!;
    final String updated = applyEdits(source, list);
    if (updated == source) return;
    File(path).writeAsStringSync(updated);
    written.add(path);
  });

  if (written.isEmpty) {
    stdout.writeln('\nNo changes to write.');
    return;
  }
  stdout.writeln('\nWrote ${written.length} file(s).');
  if (options.format) _format(written, target);
}

/// Picks the candidates a `--at` line refers to.
///
/// Widgets starting on that line win outright. Failing that — the usual case,
/// since a cursor normally sits on an argument line inside a widget — every
/// widget spanning the line is offered, innermost first, so the choice is the
/// caller's rather than a guess.
List<Candidate> _narrowToSpot(List<Candidate> found, int line) {
  final List<Candidate> exact =
      found.where((Candidate c) => c.line == line).toList();
  if (exact.isNotEmpty) return exact;

  return found.where((Candidate c) => c.spansLine(line)).toList()
    ..sort((Candidate a, Candidate b) => a.span.compareTo(b.span));
}

// ─────────────────────────────────────────────────────────────────────────────
// Edit application
// ─────────────────────────────────────────────────────────────────────────────

/// Turns every candidate into edits and applies them to [source].
///
/// Edits are applied in descending offset order so that applying one never
/// invalidates the offsets of those not yet applied.
String applyEdits(String source, List<Candidate> candidates) {
  final List<_Edit> edits = <_Edit>[];
  for (final Candidate c in candidates) {
    edits.addAll(_editsFor(c, source));
  }
  if (edits.isEmpty) return source;

  edits.sort((_Edit a, _Edit b) => b.offset.compareTo(a.offset));

  final List<String> chunks = <String>[];
  int cursor = source.length;
  for (final _Edit edit in edits) {
    chunks.add(source.substring(edit.offset + edit.length, cursor));
    chunks.add(edit.text);
    cursor = edit.offset;
  }
  chunks.add(source.substring(0, cursor));

  final StringBuffer out = StringBuffer();
  for (final String chunk in chunks.reversed) {
    out.write(chunk);
  }
  return out.toString();
}

List<_Edit> _editsFor(Candidate c, String source) {
  switch (c.action) {
    case CandidateAction.none:
      return const <_Edit>[];

    case CandidateAction.rename:
      final String quote = _quoteOf(source, c.offset);
      return <_Edit>[
        _Edit(c.offset, c.end - c.offset, '$quote${c.id}$quote'),
        ..._extraArgEdits(c),
      ];

    case CandidateAction.rewrap:
      // Drop the inline argument, then wrap the widget it sat on. The wrapper
      // carries the id, so it is not left duplicated in two places.
      final ExistingSpans rewrap = c.spans!;
      return <_Edit>[
        _Edit(rewrap.argStart!, rewrap.argEnd! - rewrap.argStart!, ''),
        _Edit(rewrap.widgetStart!, 0, _wrapPrefix(c)),
        _Edit(rewrap.widgetEnd!, 0, ',\n)'),
      ];

    case CandidateAction.remove:
      final ExistingSpans spans = c.spans!;
      if (spans.canUnwrap) {
        // Two deletions around the child: everything from the helper call's
        // start up to the child, and everything after the child to its close.
        // Whatever arguments the call carried go with the first deletion.
        return <_Edit>[
          _Edit(spans.callStart!, spans.childStart! - spans.callStart!, ''),
          _Edit(spans.childEnd!, spans.callEnd! - spans.childEnd!, ''),
        ];
      }
      return <_Edit>[_Edit(spans.argStart!, spans.argEnd! - spans.argStart!, '')];

    case CandidateAction.add:
      if (c.treatment == Treatment.inline) {
        return <_Edit>[
          _Edit(c.argsInsertAt, 0, "${c.paramName}: '${c.id}', "),
          ..._extraArgEdits(c),
        ];
      }
      return <_Edit>[
        _Edit(c.offset, 0, _wrapPrefix(c)),
        _Edit(c.end, 0, ',\n)'),
      ];
  }
}

/// Opening of a `SemanticHelper` call, up to and including `child: `.
String _wrapPrefix(Candidate c) {
  final StringBuffer prefix = StringBuffer()
    ..writeln('SemanticHelper.${c.helper}(')
    ..writeln(
      "testId: SemanticHelper.createTestId(SemanticTypes.${c.semanticType}, '${c.id}'),",
    );
  c.extraArgs.forEach((String key, String value) {
    prefix.writeln('$key: $value,');
  });
  prefix.write('child: ');
  return prefix.toString();
}

/// Extra named arguments requested on a widget that is not being wrapped: they
/// either replace an argument already there or get inserted into the call.
List<_Edit> _extraArgEdits(Candidate c) {
  if (c.extraArgs.isEmpty) return const <_Edit>[];
  final ExistingSpans? spans = c.spans;
  final int insertAt = spans?.paramInsertAt ?? c.argsInsertAt;
  final List<_Edit> edits = <_Edit>[];

  c.extraArgs.forEach((String name, String value) {
    final List<int>? present = spans?.argValueSpans[name];
    if (present != null) {
      edits.add(_Edit(present[0], present[1] - present[0], value));
    } else {
      edits.add(_Edit(insertAt, 0, '$name: $value, '));
    }
  });
  return edits;
}

/// The quote character used by the string literal starting at [offset].
String _quoteOf(String source, int offset) {
  for (int i = offset; i < source.length && i < offset + 3; i++) {
    final String ch = source[i];
    if (ch == "'" || ch == '"') return ch;
  }
  return "'";
}

class _Edit {
  _Edit(this.offset, this.length, this.text);

  final int offset;

  /// Characters replaced. Zero for a pure insertion.
  final int length;

  final String text;
}

// ─────────────────────────────────────────────────────────────────────────────
// Naming phase
// ─────────────────────────────────────────────────────────────────────────────

void _nameAll(
  Map<String, List<Candidate>> byFile,
  IdRegistry registry,
  _NameCache cache,
  String target, {
  required bool auto,
  required bool review,
}) {
  final Iterable<Candidate> all = byFile.values
      .expand((List<Candidate> l) => l)
      .where((Candidate c) => !c.isExisting);
  final int asking =
      review ? all.length : all.where((Candidate c) => c.needsPrompt).length;

  if (!auto && asking > 0) {
    stdout.writeln(
      review
          ? 'Reviewing all $asking widget(s). '
              'Enter = keep the name shown, s = skip, q = accept all remaining.\n'
          : '$asking widget(s) carry no text to name them. '
              'Enter = accept suggestion, s = skip, q = accept all remaining.\n',
    );
  }

  bool acceptRest = auto;

  byFile.forEach((String path, List<Candidate> list) {
    final String rel = p.relative(path, from: target);
    for (final Candidate c in list) {
      // Keyed by line, not by an ordinal. An ordinal counts within whatever
      // subset this run collected, so `--at` — which keeps one candidate —
      // would make it widget #0 and collide with a different widget's name
      // from a full run.
      final String key = '$rel|${c.line}|${c.widgetName}';

      // An id already in the source is kept as it stands. It is listed so it
      // can be renamed or removed from the summary, not re-asked here.
      if (c.isExisting) {
        c.id = c.originalId;
        continue;
      }

      final String? cached = cache.get(key);
      final String fallback =
          cached ?? c.autoName ?? c.suggestion ?? slugify(c.widgetName);

      // Outside review mode a widget that named itself is not worth a question.
      if (!review && c.autoName != null) {
        c.id = registry.claim(c.autoName!);
        continue;
      }
      if (!review && cached != null) {
        c.id = registry.claim(cached);
        continue;
      }
      if (acceptRest) {
        c.id = registry.claim(fallback);
        continue;
      }

      final String? answer = _ask(c, rel, fallback);
      if (answer == null) {
        c.id = null;
        continue;
      }
      if (answer == '__ACCEPT_REST__') {
        acceptRest = true;
        c.id = registry.claim(fallback);
        continue;
      }
      final String chosen = answer.isEmpty ? fallback : slugify(answer);
      if (chosen != c.autoName) cache.set(key, chosen);
      c.id = registry.claim(chosen);
    }
  });
}

/// Returns the typed name, '' to accept the suggestion, null to skip, or the
/// accept-all sentinel.
String? _ask(Candidate c, String relativePath, String fallback) {
  stdout.writeln('$relativePath:${c.line}');
  final String action = c.treatment == Treatment.wrap
      ? 'SemanticHelper.${c.helper}'
      : '${c.paramName}:';
  stdout.writeln('  ${c.widgetName}  ->  $action');
  final String where = <String?>[
    if (c.enclosingMethod != null) 'in ${c.enclosingMethod}',
    if (c.enclosingClass != null) 'class ${c.enclosingClass}',
  ].whereType<String>().join('  .  ');
  if (where.isNotEmpty) stdout.writeln('  $where');
  if (c.nearbyText != null) stdout.writeln('  nearby text: ${c.nearbyText}');
  stdout.writeln('  suggested: $fallback');
  stdout.write('  name > ');

  final String? line = stdin.readLineSync();
  stdout.writeln();
  if (line == null) return '';
  final String trimmed = line.trim();
  if (trimmed == 's') return null;
  if (trimmed == 'q') return '__ACCEPT_REST__';
  return trimmed;
}

// ─────────────────────────────────────────────────────────────────────────────
// Reporting
// ─────────────────────────────────────────────────────────────────────────────

void _reportFacts(ProjectFacts facts) {
  stdout.writeln(
    '  ${facts.semanticParams.length} widget(s) accept a semantic id argument.',
  );
  if (facts.foundSemanticTypesClass) {
    stdout.writeln(
      '  SemanticTypes: ${facts.semanticTypes.members.length} member(s) found.',
    );
  } else {
    stdout.writeln(
      '  SemanticTypes class not found — falling back to '
      '${SemanticTypesCatalog.confirmed.join(", ")}.',
    );
  }
}

/// Prints the numbered summary and returns the candidates in printed order, so
/// a row number typed at the confirm prompt maps back to the right widget.
List<Candidate> _printSummary(Map<String, List<Candidate>> byFile, String target) {
  final List<Candidate> ordered = <Candidate>[];
  stdout.writeln('\n${'─' * 74}');
  byFile.forEach((String path, List<Candidate> list) {
    stdout.writeln('\n${p.relative(path, from: target)}');
    for (final Candidate c in list) {
      ordered.add(c);
      _printRow(ordered.length, c);
    }
  });
  stdout.writeln('\n${'─' * 74}');
  stdout.writeln('${ordered.length} edit(s) across ${byFile.length} file(s).');
  return ordered;
}

void _printRow(int number, Candidate c) {
  stdout.writeln(
    '  ${number.toString().padLeft(3)}.  '
    '${c.line.toString().padLeft(5)}  '
    '${c.widgetName.padRight(22)} ${_how(c).padRight(26)} ${_outcome(c)}',
  );
}

String _how(Candidate c) {
  if (c.isExisting) {
    return c.helper != null ? 'has SemanticHelper.${c.helper}' : 'has ${c.paramName}';
  }
  return c.treatment == Treatment.inline
      ? '${c.paramName}'
      : 'SemanticHelper.${c.helper}';
}

String _outcome(Candidate c) {
  final String extras = c.extraArgs.isEmpty
      ? ''
      : '  + ${c.extraArgs.entries.map((MapEntry<String, String> e) => '${e.key}: ${e.value}').join(', ')}';
  switch (c.action) {
    case CandidateAction.remove:
      return c.spans!.canUnwrap
          ? 'REMOVE (unwrap, keeps child)'
          : 'REMOVE (drop ${c.paramName})';
    case CandidateAction.rewrap:
      return 'SemanticHelper.${c.helper} carries ${c.id}$extras';
    case CandidateAction.none:
      return c.isExisting ? '${c.originalId}  (unchanged)' : '(skipped)';
    case CandidateAction.rename:
      return c.id == c.originalId
          ? '${c.id}$extras'
          : '${c.originalId}  ->  ${c.id}$extras';
    case CandidateAction.add:
      return '${c.id}$extras';
  }
}

/// Final gate: a numbered menu, then follow-up questions for whatever is picked.
///
/// Deliberately one number at a time rather than a command syntax: the person
/// running this is usually acting on a QA ticket, not memorising flags.
bool _confirmOrEdit(
  List<Candidate> ordered,
  IdRegistry registry,
  ProjectFacts facts,
) {
  while (true) {
    stdout.writeln('');
    stdout.writeln('What do you want to do?');
    stdout.writeln('  1  apply all the edits above');
    stdout.writeln('  2  cancel, change nothing');
    stdout.writeln('  3  rename one');
    stdout.writeln('  4  give one a value');
    stdout.writeln('  5  wrap one so it can carry a value');
    stdout.writeln('  6  take the id away from one');
    stdout.writeln('  7  leave one alone');
    stdout.writeln('  8  show the list again');
    stdout.writeln('');
    stdout.write('> ');

    final String choice = (stdin.readLineSync() ?? '').trim().toLowerCase();

    if (choice == '1' || choice == 'y' || choice == 'yes') return true;
    if (choice == '2' || choice == 'n' || choice == 'no' || choice.isEmpty) {
      return false;
    }
    if (choice == '8' || choice == 'l') {
      for (int i = 0; i < ordered.length; i++) {
        _printRow(i + 1, ordered[i]);
      }
      continue;
    }
    if (!<String>['3', '4', '5', '6', '7'].contains(choice)) {
      stdout.writeln('Please type a number from 1 to 8.');
      continue;
    }

    final int? row = _askRow(ordered.length);
    if (row == null) continue;
    final Candidate c = ordered[row - 1];

    switch (choice) {
      case '3':
        _rename(c, registry);
      case '4':
        _setParameter(c, facts);
      case '5':
        _requestWrap(c, facts);
      case '6':
        _requestRemove(c, registry);
      case '7':
        _requestSkip(c, registry);
    }
    stdout.writeln();
    _printRow(row, c);
  }
}

/// Asks which row to act on. Null means they changed their mind.
int? _askRow(int rows) {
  while (true) {
    stdout.write('Which one? (1-$rows, or Enter to go back) > ');
    final String raw = (stdin.readLineSync() ?? '').trim();
    if (raw.isEmpty) return null;
    final int? row = int.tryParse(raw);
    if (row != null && row >= 1 && row <= rows) return row;
    stdout.writeln('  There is no row $raw. Pick a number from 1 to $rows.');
  }
}

void _rename(Candidate c, IdRegistry registry) {
  if (c.removeRequested) {
    stdout.writeln('  This one was set to be removed; renaming cancels that.');
    c.removeRequested = false;
  }
  stdout.writeln('\n  ${c.widgetName} at line ${c.line}, currently "${c.id}"');
  stdout.write('  new name (Enter to keep) > ');
  final String typed = (stdin.readLineSync() ?? '').trim();
  if (typed.isEmpty) {
    stdout.writeln('  unchanged.');
    return;
  }
  if (c.id != null) registry.release(c.id!);
  c.id = registry.claim(slugify(typed));
}

void _requestRemove(Candidate c, IdRegistry registry) {
  if (!c.canRemove) {
    stdout.writeln(
      c.isExisting
          ? '  Cannot remove this one — its id is not a plain literal argument.'
          : '  Nothing to remove; this one has no id yet. '
          'Pick option 7 to leave it alone.',
    );
    return;
  }
  c.removeRequested = true;
  if (c.id != null) registry.release(c.id!);
  stdout.writeln(
    c.spans!.canUnwrap
        ? '  Will unwrap the SemanticHelper call and keep the child widget.'
        : '  Will drop the ${c.paramName} argument.',
  );
}

void _requestSkip(Candidate c, IdRegistry registry) {
  c.removeRequested = false;
  if (c.isExisting) {
    c.id = c.originalId;
    c.extraArgs.clear();
    stdout.writeln('  Left as it is.');
    return;
  }
  if (c.id != null) registry.release(c.id!);
  c.id = null;
  stdout.writeln('  Skipped — no id will be added.');
}

/// Trades an inline id for a `SemanticHelper` wrapper.
///
/// This is the way out when a harness needs a field the widget has no
/// parameter for — `FusionAppText` takes a `semanticId` but no `value`, so the
/// text can only be published by a node wrapped around it.
void _requestWrap(Candidate c, ProjectFacts facts) {
  if (!c.canRewrap) {
    stdout.writeln(
      c.isExisting
          ? '  Only an inline id can be traded for a wrapper; this one is '
              'already a SemanticHelper call.'
          : '  This row is not an existing inline id.',
    );
    return;
  }

  c.wrapRequested = true;
  c.removeRequested = false;
  final bool isText = textWidgets.contains(c.widgetName);
  c.helper = isText ? 'staticText' : 'container';
  c.semanticType = facts.semanticTypes.resolve(isText ? 'text' : 'section');

  stdout.writeln(
    '\n  ${c.widgetName} will be wrapped in SemanticHelper.${c.helper}, '
    'carrying "${c.id}".',
  );
  stdout.writeln('  Its inline ${c.paramName} argument is dropped, so the id '
      'is not duplicated.');
  stdout.writeln('  Pick option 4 to fill in '
      '${(helperParams[c.helper!] ?? const <String>[]).join(' or ')}.');
}

/// Adds or replaces a named argument such as `value` or `enabled`.
///
/// The fields are offered as a numbered list rather than typed, so there is no
/// way to name one the target does not have.
void _setParameter(Candidate c, ProjectFacts facts) {
  if (c.removeRequested) {
    stdout.writeln('  This one is set to be removed. Pick option 7 first.');
    return;
  }

  // Where the argument lands decides which fields are legal: a wrapped row
  // writes into the SemanticHelper call, a bare one onto the widget itself.
  final bool ontoHelper = c.helper != null;
  final List<String> fields = ontoHelper
      ? (helperParams[c.helper!] ?? const <String>[])
      : (facts.widgetParams[c.widgetName]?.toList() ?? const <String>[]);

  stdout.writeln('');
  stdout.writeln('  ${c.widgetName} at line ${c.line}');

  if (fields.isEmpty) {
    stdout.writeln('  No fields known for this one, so nothing can be set.');
    return;
  }

  stdout.writeln('  Which field?');
  for (int i = 0; i < fields.length; i++) {
    stdout.writeln('    ${i + 1}  ${fields[i]}');
  }
  stdout.write('  > ');

  final String pick = (stdin.readLineSync() ?? '').trim();
  if (pick.isEmpty) return;
  final int? index = int.tryParse(pick);
  if (index == null || index < 1 || index > fields.length) {
    stdout.writeln('  Pick a number from 1 to ${fields.length}.');
    return;
  }
  final String name = fields[index - 1];

  if (!ontoHelper && name == 'value' && c.nearbyText == null) {
    stdout.writeln('  Nothing to use as a value here.');
    return;
  }

  if (c.nearbyText != null) {
    stdout.writeln('  Enter alone uses its text: ${c.nearbyText}');
  }
  stdout.write('  What should "$name" be? > ');
  final String raw = (stdin.readLineSync() ?? '').trim();
  final String value = raw.isEmpty ? (c.nearbyText ?? '') : raw;
  if (value.isEmpty) {
    stdout.writeln('  Nothing entered, left unchanged.');
    return;
  }
  c.extraArgs[name] = value;
}

// ─────────────────────────────────────────────────────────────────────────────
// Formatting
// ─────────────────────────────────────────────────────────────────────────────

/// Reformats the files that changed.
///
/// Wrapping inserts structurally correct but unindented code. Formatting fixes
/// that, but only when the project's page width is known — guessing it would
/// reflow every untouched line in the file and bury the real diff.
void _format(List<String> files, String target) {
  final int? width = _pageWidth(target);
  if (width == null) {
    stdout.writeln(
      '\nNo formatter page_width in analysis_options.yaml — skipped formatting.\n'
      'The output is valid Dart but the new wrappers are unindented.\n'
      'Run your own formatter over the changed files to tidy them.',
    );
    return;
  }
  final ProcessResult result = Process.runSync(
    'dart',
    <String>['format', '--line-length=$width', ...files],
    runInShell: true,
  );
  if (result.exitCode == 0) {
    stdout.writeln('Formatted at page width $width.');
  } else {
    stderr.writeln('dart format failed: ${result.stderr}');
  }
}

/// Reads `formatter: page_width:` out of the nearest analysis_options.yaml.
int? _pageWidth(String target) {
  Directory dir = Directory(p.normalize(p.absolute(target)));
  while (true) {
    final File file = File(p.join(dir.path, 'analysis_options.yaml'));
    if (file.existsSync()) {
      final RegExpMatch? match = RegExp(
        r'page_width\s*:\s*(\d+)',
      ).firstMatch(file.readAsStringSync());
      if (match != null) return int.parse(match.group(1)!);
    }
    final Directory parent = dir.parent;
    if (parent.path == dir.path) return null;
    dir = parent;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Input / cache / options
// ─────────────────────────────────────────────────────────────────────────────

String? _resolveTarget(String? fromArgs) {
  String? input = fromArgs;
  if (input == null) {
    stdout.write('Enter directory path: ');
    input = stdin.readLineSync()?.trim();
  }
  if (input == null || input.isEmpty) {
    stderr.writeln('No directory given.');
    return null;
  }
  // Tolerate a path pasted with surrounding quotes.
  if (input.length > 1 &&
      ((input.startsWith('"') && input.endsWith('"')) ||
          (input.startsWith("'") && input.endsWith("'")))) {
    input = input.substring(1, input.length - 1);
  }
  final String resolved = p.normalize(p.absolute(input));
  if (!Directory(resolved).existsSync()) {
    stderr.writeln('Not a directory: $resolved');
    return null;
  }
  return resolved;
}

List<File> _dartFilesIn(String dir) {
  final List<File> out = <File>[];
  for (final FileSystemEntity e
      in Directory(dir).listSync(recursive: true, followLinks: false)) {
    if (e is! File || !e.path.endsWith('.dart')) continue;
    final String path = e.path.replaceAll(r'\', '/');
    if (path.contains('/.dart_tool/') || path.contains('/build/')) continue;
    if (path.endsWith('.g.dart') ||
        path.endsWith('.freezed.dart') ||
        path.endsWith('.gr.dart')) {
      continue;
    }
    out.add(e);
  }
  out.sort((File a, File b) => a.path.compareTo(b.path));
  return out;
}

/// Remembers names typed for widgets that have no text, so an aborted run does
/// not ask the same questions again.
class _NameCache {
  _NameCache(this._entries);

  final Map<String, String> _entries;

  static _NameCache load(String target) {
    final File file = File(p.join(target, _cacheFileName));
    if (!file.existsSync()) return _NameCache(<String, String>{});
    try {
      final Map<String, dynamic> raw =
          jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      return _NameCache(raw.map((String k, dynamic v) => MapEntry<String, String>(k, v as String)));
    } on Object {
      return _NameCache(<String, String>{});
    }
  }

  String? get(String key) => _entries[key];

  void set(String key, String value) => _entries[key] = value;

  void save(String target) {
    if (_entries.isEmpty) return;
    File(p.join(target, _cacheFileName))
        .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(_entries));
  }
}

/// A `file.dart:214` location naming one widget to work on.
class _Spot {
  _Spot(this.filePath, this.line);

  final String filePath;
  final int line;

  String get directory => p.dirname(filePath);

  /// Returns null and explains itself if [raw] is not `<file>:<line>`.
  static _Spot? parse(String raw) {
    final int colon = raw.lastIndexOf(':');
    // Guard against a Windows drive letter being read as the separator.
    if (colon <= 1) {
      stderr.writeln('--at needs <file>:<line>, for example --at=lib/panel.dart:214');
      return null;
    }
    final int? line = int.tryParse(raw.substring(colon + 1));
    if (line == null || line < 1) {
      stderr.writeln('--at line must be a positive number: $raw');
      return null;
    }
    final String file = p.normalize(p.absolute(raw.substring(0, colon)));
    if (!File(file).existsSync()) {
      stderr.writeln('No such file: $file');
      return null;
    }
    return _Spot(file, line);
  }
}

class _Options {
  _Options({
    required this.dryRun,
    required this.auto,
    required this.review,
    required this.editExisting,
    required this.at,
    required this.format,
    required this.scanRoots,
    required this.path,
  });

  final bool dryRun;
  final bool auto;

  /// Ask about every widget, including ones that named themselves from text.
  final bool review;

  /// List ids already in the source so they can be renamed or removed.
  final bool editExisting;

  /// `file.dart:214` — work on one widget, bypassing the skip rules.
  final String? at;

  final bool format;
  final List<String> scanRoots;
  final String? path;

  static _Options parse(List<String> argv) {
    bool dryRun = false;
    bool auto = false;
    bool review = false;
    bool editExisting = false;
    bool format = true;
    String? at;
    final List<String> scanRoots = <String>[];
    String? path;

    for (final String arg in argv) {
      if (arg == '--dry-run') {
        dryRun = true;
      } else if (arg == '--auto') {
        auto = true;
      } else if (arg == '--review' || arg == '--step') {
        review = true;
      } else if (arg == '--edit-existing' || arg == '--existing') {
        editExisting = true;
      } else if (arg.startsWith('--at=')) {
        at = arg.substring('--at='.length);
      } else if (arg == '--no-format') {
        format = false;
      } else if (arg.startsWith('--scan=')) {
        scanRoots.add(arg.substring('--scan='.length));
      } else if (!arg.startsWith('-')) {
        path = arg;
      }
    }
    return _Options(
      dryRun: dryRun,
      auto: auto,
      review: review,
      editExisting: editExisting,
      at: at,
      format: format,
      scanRoots: scanRoots,
      path: path,
    );
  }
}
