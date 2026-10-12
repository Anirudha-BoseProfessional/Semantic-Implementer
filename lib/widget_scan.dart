/// Syntactic discovery of project facts the rewriter needs:
/// which widget classes accept a semantic id, and what `SemanticTypes` defines.
///
/// This is deliberately parse-only rather than a resolved element lookup.
/// Resolution needs the target to have had `pub get` run and pins the tool to
/// one analyzer element-model major; parsing constructor parameter names gives
/// the same answer and keeps working across analyzer versions.
library;

import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/features.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:path/path.dart' as p;

import 'rules.dart';

/// SDK packages that resolve to local paths but must never be scanned.
const Set<String> _sdkPackages = <String>{
  'flutter',
  'flutter_test',
  'flutter_driver',
  'flutter_localizations',
  'flutter_web_plugins',
  'integration_test',
  'sky_engine',
};

/// What a scan of the project turned up.
class ProjectFacts {
  ProjectFacts({
    required this.semanticParams,
    required this.semanticTypes,
    required this.scannedRoots,
    required this.foundSemanticTypesClass,
    required this.projectWidgets,
    required this.widgetParams,
  });

  /// Widget class name -> the semantic id parameter it accepts.
  final Map<String, String> semanticParams;

  /// Widget class name -> every named constructor parameter it accepts.
  ///
  /// Used to warn before writing an argument a widget does not have. Only
  /// covers classes on a scanned path; framework widgets are absent, so an
  /// unknown name is a "cannot confirm", not a "does not exist".
  final Map<String, Set<String>> widgetParams;

  /// Widget classes declared inside the target directory.
  ///
  /// These are never wrapped where they are used: this same run instruments
  /// their own `build` methods, so wrapping the use site too would put two
  /// nodes around one subtree. Widgets from scanned *dependencies* are
  /// deliberately excluded — this run is not instrumenting those, so they are
  /// ordinary leaf widgets that may need wrapping.
  final Set<String> projectWidgets;

  /// Members declared on `SemanticTypes`.
  final SemanticTypesCatalog semanticTypes;

  /// Directories that were actually read.
  final List<String> scannedRoots;

  /// False when `SemanticTypes` was never located, meaning the catalog is the
  /// confirmed-members fallback rather than the project's real list.
  final bool foundSemanticTypesClass;
}

/// Walks [dirs] plus any local path-dependency packages of the target, and
/// records the facts the rewriter needs.
ProjectFacts scanProject(String targetDir, {List<String> extraRoots = const <String>[]}) {
  final List<String> roots = <String>[
    targetDir,
    ...extraRoots,
    ..._localPackageRoots(targetDir),
  ];

  final Map<String, String> params = <String, String>{...seedSemanticParams};
  final Set<String> types = <String>{};
  final Set<String> widgets = <String>{};
  final Map<String, Set<String>> allParams = <String, Set<String>>{};
  final List<String> scanned = <String>[];
  bool foundTypes = false;

  final String normalizedTarget = p.normalize(p.absolute(targetDir));

  for (final String root in roots) {
    final Directory dir = Directory(root);
    if (!dir.existsSync()) continue;
    scanned.add(root);
    final String normalizedRoot = p.normalize(p.absolute(root));
    final bool isTarget = normalizedRoot == normalizedTarget ||
        p.isWithin(normalizedTarget, normalizedRoot);
    for (final File file in _dartFiles(dir)) {
      final CompilationUnit? unit = _parse(file.path);
      if (unit == null) continue;
      for (final CompilationUnitMember member in unit.declarations) {
        if (member is! ClassDeclaration) continue;
        final String className = member.name.lexeme;

        if (className == 'SemanticTypes') {
          foundTypes = true;
          types.addAll(_constantNames(member));
          continue;
        }

        if (isTarget && _isWidgetClass(member)) widgets.add(className);

        final Set<String> accepted = _constructorParams(member);
        if (accepted.isNotEmpty) {
          allParams.putIfAbsent(className, () => <String>{}).addAll(accepted);
        }

        final String? param = _semanticParamOf(member);
        if (param != null) params[className] = param;
      }
    }
  }

  return ProjectFacts(
    semanticParams: params,
    semanticTypes: SemanticTypesCatalog(types),
    scannedRoots: scanned,
    foundSemanticTypesClass: foundTypes,
    projectWidgets: widgets,
    widgetParams: allParams,
  );
}

/// Whether the class is a Flutter widget the project declares itself.
bool _isWidgetClass(ClassDeclaration cls) {
  final String? superclass = cls.extendsClause?.superclass.toSource();
  if (superclass == null) return false;
  return superclass.startsWith('StatelessWidget') ||
      superclass.startsWith('StatefulWidget') ||
      superclass.startsWith('ConsumerWidget') ||
      superclass.startsWith('ConsumerStatefulWidget') ||
      superclass.endsWith('Widget');
}

/// Names of the string constants a `SemanticTypes`-style class declares.
Set<String> _constantNames(ClassDeclaration cls) {
  final Set<String> out = <String>{};
  for (final ClassMember m in cls.members) {
    if (m is! FieldDeclaration) continue;
    for (final VariableDeclaration v in m.fields.variables) {
      out.add(v.name.lexeme);
    }
  }
  return out;
}

/// Every named parameter this class's constructors accept.
Set<String> _constructorParams(ClassDeclaration cls) {
  final Set<String> out = <String>{};
  for (final ClassMember m in cls.members) {
    if (m is! ConstructorDeclaration) continue;
    for (final FormalParameter param in m.parameters.parameters) {
      if (!param.isNamed) continue;
      final String? name = param.name?.lexeme;
      if (name != null) out.add(name);
    }
  }
  return out;
}

/// The semantic id parameter this class's constructors accept, if any.
String? _semanticParamOf(ClassDeclaration cls) {
  for (final ClassMember m in cls.members) {
    if (m is! ConstructorDeclaration) continue;
    for (final FormalParameter param in m.parameters.parameters) {
      final String? name = param.name?.lexeme;
      if (name == null) continue;
      if (semanticParamNames.contains(name)) return name;
    }
  }
  return null;
}

CompilationUnit? _parse(String path) {
  try {
    final ParseStringResult result = parseFile(
      path: path,
      featureSet: FeatureSet.latestLanguageVersion(),
      throwIfDiagnostics: false,
    );
    return result.unit;
  } on Object {
    return null;
  }
}

Iterable<File> _dartFiles(Directory dir) sync* {
  for (final FileSystemEntity e in dir.listSync(recursive: true, followLinks: false)) {
    if (e is! File || !e.path.endsWith('.dart')) continue;
    final String path = e.path.replaceAll(r'\', '/');
    if (path.contains('/.dart_tool/') || path.contains('/build/')) continue;
    if (path.endsWith('.g.dart') || path.endsWith('.freezed.dart')) continue;
    yield e;
  }
}

/// Reads the target's `package_config.json` and returns the `lib/` directories
/// of packages that live on local paths — a monorepo's own design-system
/// packages, where widgets like `FusionAppText` are declared. Pub-cache
/// packages are skipped; scanning those would cost minutes for no gain.
List<String> _localPackageRoots(String targetDir) {
  final File? config = _findPackageConfig(targetDir);
  if (config == null) return <String>[];

  try {
    final Map<String, dynamic> json =
        jsonDecode(config.readAsStringSync()) as Map<String, dynamic>;
    final List<dynamic> packages = (json['packages'] as List<dynamic>?) ?? <dynamic>[];
    final List<String> out = <String>[];

    // Packages must live near the target to be scanned. Without this the
    // Flutter SDK itself qualifies as a "local path" package: scanning it costs
    // minutes and, worse, would declare Container and Row as widget classes.
    final String neighbourhood = p.dirname(p.normalize(config.parent.parent.path));

    for (final dynamic entry in packages) {
      if (entry is! Map<String, dynamic>) continue;
      final String? rootUri = entry['rootUri'] as String?;
      final String? name = entry['name'] as String?;
      if (rootUri == null || name == null) continue;
      if (_sdkPackages.contains(name)) continue;

      final String resolved = _resolveRoot(rootUri, config.parent.path);
      final String normalized = resolved.replaceAll(r'\', '/');
      if (normalized.contains('/.pub-cache/') || normalized.contains('/hosted/')) {
        continue;
      }
      if (!p.isWithin(neighbourhood, resolved)) continue;

      final String lib = p.join(resolved, 'lib');
      if (Directory(lib).existsSync()) out.add(lib);
    }
    return out;
  } on Object {
    return <String>[];
  }
}

String _resolveRoot(String rootUri, String configDir) {
  if (rootUri.startsWith('file:')) {
    return p.normalize(Uri.parse(rootUri).toFilePath());
  }
  return p.normalize(p.join(configDir, rootUri));
}

/// Walks up from [start] looking for `.dart_tool/package_config.json`.
File? _findPackageConfig(String start) {
  Directory dir = Directory(p.normalize(p.absolute(start)));
  while (true) {
    final File candidate = File(p.join(dir.path, '.dart_tool', 'package_config.json'));
    if (candidate.existsSync()) return candidate;
    final Directory parent = dir.parent;
    if (parent.path == dir.path) return null;
    dir = parent;
  }
}
