/// Finds widget expressions that need a semantic id and describes the edit.
///
/// Analysis and editing are separate phases: this module only produces
/// [Candidate]s. Nothing is written until every candidate has been named, so a
/// run can be abandoned mid-prompt without having touched the tree.
library;

import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/source/line_info.dart';

import 'naming.dart';
import 'rules.dart';
import 'widget_scan.dart';

/// What will be done to a candidate when edits are applied.
enum CandidateAction {
  /// Leave the source untouched — a skipped row, or an existing id kept as is.
  none,

  /// Add an id: an inline argument, or a new `SemanticHelper` wrapper.
  add,

  /// Rewrite an existing id literal in place.
  rename,

  /// Take the id away: drop the inline argument, or unwrap the helper call.
  remove,

  /// Trade an inline id for a `SemanticHelper` wrapper, so the node can carry
  /// fields the widget itself has no parameter for — `value`, `label`.
  rewrap,
}

/// Offsets needed to modify a widget that already carries an id.
class ExistingSpans {
  const ExistingSpans({
    required this.paramInsertAt,
    required this.argValueSpans,
    this.argStart,
    this.argEnd,
    this.widgetStart,
    this.widgetEnd,
    this.callStart,
    this.childStart,
    this.childEnd,
    this.callEnd,
  });

  /// Where a new named argument can be inserted on the owning call.
  final int paramInsertAt;

  /// Argument name -> `[start, end]` of its value, for arguments already
  /// present, so setting one replaces it rather than duplicating it.
  final Map<String, List<int>> argValueSpans;

  /// Inline form: span of the `semanticId: 'x'` argument, trailing comma
  /// included, so removing it leaves a valid argument list.
  final int? argStart;
  final int? argEnd;

  /// Inline form: span of the widget that holds the argument, so the id can be
  /// traded for a wrapper around that widget.
  final int? widgetStart;
  final int? widgetEnd;

  /// Wrapped form: the helper call and the child inside it.
  final int? callStart;
  final int? childStart;
  final int? childEnd;
  final int? callEnd;

  /// Start of whichever construct owns the id — the widget for an inline one,
  /// the helper call for a wrapped one.
  int? get ownerStart => widgetStart ?? callStart;

  int? get ownerEnd => widgetEnd ?? callEnd;

  bool get canUnwrap => callStart != null;

  bool get canDropArgument => argStart != null;

  /// Whether the inline id can be traded for a `SemanticHelper` wrapper.
  bool get canRewrap => argStart != null && widgetStart != null;
}

/// One widget that should receive a semantic id.
class Candidate {
  Candidate({
    required this.filePath,
    required this.line,
    required this.endLine,
    required this.widgetName,
    required this.treatment,
    required this.offset,
    required this.end,
    required this.argsInsertAt,
    required this.needsPrompt,
    this.paramName,
    this.helper,
    this.semanticType,
    Map<String, String>? extraArgs,
    this.spans,
    this.autoName,
    this.suggestion,
    this.enclosingMethod,
    this.enclosingClass,
    this.nearbyText,
    this.originalId,
  }) : extraArgs = <String, String>{...?extraArgs};

  final String filePath;

  /// Line the widget starts on.
  final int line;

  /// Line the widget ends on. A widget usually spans several lines, and a
  /// caller pointing at one of the inner ones still means this widget.
  final int endLine;

  final String widgetName;
  final Treatment treatment;

  bool spansLine(int target) => target >= line && target <= endLine;

  /// How many lines the widget covers; smaller means more deeply nested.
  int get span => endLine - line;

  /// Start of the widget expression — or, for [Treatment.existing], of the id
  /// string literal that a rename replaces.
  final int offset;

  /// End of the widget expression, or of the existing id literal.
  final int end;

  /// Offset just past the opening parenthesis, where an inline argument goes.
  final int argsInsertAt;

  /// True when the tool has no text to name this widget from.
  final bool needsPrompt;

  /// Inline only: the argument name this widget accepts.
  final String? paramName;

  /// Wrap only: `SemanticHelper` method. Mutable, since trading an inline id
  /// for a wrapper has to choose one.
  String? helper;

  /// Wrap only: resolved `SemanticTypes` member.
  String? semanticType;

  /// Extra named arguments to emit, already rendered as source. On a wrap they
  /// go into the helper call; otherwise onto the widget itself. Mutable: the
  /// confirm prompt can add to it.
  final Map<String, String> extraArgs;

  /// Existing only: the offsets needed to rename, remove, or add arguments.
  final ExistingSpans? spans;

  final String? autoName;
  final String? suggestion;
  final String? enclosingMethod;
  final String? enclosingClass;
  final String? nearbyText;

  /// Existing only: the id as it currently appears in the source.
  final String? originalId;

  /// Assigned during the naming phase. Null means the row is skipped.
  String? id;

  /// Set when the user asks for this widget's id to be taken away.
  bool removeRequested = false;

  /// Set when the user asks for an inline id to become a wrapper instead.
  bool wrapRequested = false;

  bool get isExisting => treatment == Treatment.existing;

  /// Whether this row can have its id removed, rather than just renamed.
  bool get canRemove =>
      isExisting && (spans?.canUnwrap == true || spans?.canDropArgument == true);

  /// What applying this row will actually do.
  CandidateAction get action {
    if (removeRequested && canRemove) return CandidateAction.remove;
    if (id == null) return CandidateAction.none;
    if (wrapRequested && canRewrap) return CandidateAction.rewrap;
    if (!isExisting) return CandidateAction.add;
    if (id != originalId || extraArgs.isNotEmpty) return CandidateAction.rename;
    return CandidateAction.none;
  }

  /// Whether this row's id can be traded for a wrapper.
  bool get canRewrap => isExisting && spans?.canRewrap == true;

  bool get changesSource => action != CandidateAction.none;
}

/// Analyses one parsed file and returns everything that needs instrumenting,
/// plus — when [includeExisting] is set — every id already in the file, as
/// renameable rows. Results are in source order.
List<Candidate> analyzeUnit({
  required String filePath,
  required CompilationUnit unit,
  required LineInfo lineInfo,
  required ProjectFacts facts,
  required IdRegistry registry,
  bool includeExisting = false,
  Set<int> forceLines = const <int>{},
}) {
  final _ExistingIdVisitor existing = _ExistingIdVisitor(
    registry,
    filePath: filePath,
    lineInfo: lineInfo,
    collect: includeExisting,
  );
  unit.accept(existing);

  final Set<int> sectionRoots = _findSectionRoots(unit);
  final _Collector collector = _Collector(
    filePath: filePath,
    lineInfo: lineInfo,
    facts: facts,
    sectionRoots: sectionRoots,
    forceLines: forceLines,
  );
  unit.accept(collector);

  return <Candidate>[...existing.found, ...collector.candidates]
    ..sort((Candidate a, Candidate b) => a.offset.compareTo(b.offset));
}

/// Finds ids already present in the source. Always reserves them, so generated
/// ids never collide; optionally records them as renameable candidates.
///
/// Only string-literal ids are recorded. An id built from a variable or an
/// interpolation cannot be renamed by rewriting one literal, so it is left be.
class _ExistingIdVisitor extends RecursiveAstVisitor<void> {
  _ExistingIdVisitor(
    this.registry, {
    required this.filePath,
    required this.lineInfo,
    required this.collect,
  });

  final IdRegistry registry;
  final String filePath;
  final LineInfo lineInfo;
  final bool collect;
  final List<Candidate> found = <Candidate>[];

  /// `FusionAppText(semanticId: 'x')` and the other direct-argument spellings.
  @override
  void visitNamedExpression(NamedExpression node) {
    final String name = node.name.label.name;
    final Expression value = node.expression;
    if (semanticParamNames.contains(name) && value is SimpleStringLiteral) {
      registry.reserve(value.value);
      final AstNode? owner = node.parent?.parent;
      final ArgumentList? ownerArgs =
          owner is Expression ? argumentListOf(owner) : null;
      if (collect && owner is Expression && ownerArgs != null) {
        _record(
          literal: value,
          widgetName: widgetNameOf(owner) ?? name,
          paramName: name,
          nearbyText: textExpressionOf(ownerArgs)?.toSource(),
          spans: ExistingSpans(
            paramInsertAt: ownerArgs.leftParenthesis.end,
            argValueSpans: _argValueSpans(ownerArgs, skip: <String>{name}),
            argStart: node.offset,
            argEnd: _endIncludingComma(node),
            widgetStart: owner.offset,
            widgetEnd: owner.end,
          ),
        );
      }
    }
    super.visitNamedExpression(node);
  }

  /// `SemanticHelper.x(testId: SemanticHelper.createTestId(type, 'x'), ...)`.
  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (node.methodName.name == 'createTestId' &&
        node.target?.toSource() == 'SemanticHelper') {
      final List<Expression> args = node.argumentList.arguments;
      if (args.length >= 2) {
        final Expression second = args[1];
        if (second is SimpleStringLiteral) {
          registry.reserve(second.value);
          if (collect) _recordHelperId(node, second);
        }
      }
    }
    super.visitMethodInvocation(node);
  }

  /// Names the row after the widget the helper wraps, since that is what a
  /// reader recognises — `GestureDetector`, not `SemanticHelper.button`.
  void _recordHelperId(MethodInvocation createTestId, SimpleStringLiteral literal) {
    String? helper;
    String widgetName = 'SemanticHelper';
    String? nearbyText;
    ExistingSpans? spans;

    final AstNode? helperCall = createTestId.parent?.parent?.parent;
    if (helperCall is MethodInvocation &&
        helperCall.target?.toSource() == 'SemanticHelper') {
      helper = helperCall.methodName.name;
      final ArgumentList args = helperCall.argumentList;
      final Expression? child = namedArgument(args, 'child');
      widgetName = (child == null ? null : widgetNameOf(child)) ?? 'SemanticHelper';
      final ArgumentList? childArgs = child == null ? null : argumentListOf(child);
      if (childArgs != null) nearbyText = textExpressionOf(childArgs)?.toSource();
      if (child != null) {
        spans = ExistingSpans(
          paramInsertAt: args.leftParenthesis.end,
          argValueSpans: _argValueSpans(args, skip: <String>{'testId', 'child'}),
          callStart: helperCall.offset,
          childStart: child.offset,
          childEnd: child.end,
          callEnd: helperCall.end,
        );
      }
    }
    _record(
      literal: literal,
      widgetName: widgetName,
      helper: helper,
      nearbyText: nearbyText,
      spans: spans,
    );
  }

  /// Value spans of the named arguments already on a call, so setting one of
  /// them replaces the value instead of adding a duplicate argument.
  Map<String, List<int>> _argValueSpans(
    ArgumentList args, {
    required Set<String> skip,
  }) {
    final Map<String, List<int>> out = <String, List<int>>{};
    for (final Expression a in args.arguments) {
      if (a is! NamedExpression) continue;
      final String name = a.name.label.name;
      if (skip.contains(name)) continue;
      out[name] = <int>[a.expression.offset, a.expression.end];
    }
    return out;
  }

  /// End offset of an argument, swallowing the comma after it when there is
  /// one, so deleting the span leaves a well-formed argument list.
  int _endIncludingComma(AstNode node) {
    final Token? next = node.endToken.next;
    if (next != null && next.lexeme == ',') return next.end;
    return node.end;
  }

  void _record({
    required SimpleStringLiteral literal,
    required String widgetName,
    String? paramName,
    String? helper,
    String? nearbyText,
    ExistingSpans? spans,
  }) {
    found.add(
      Candidate(
        filePath: filePath,
        // Lines come from the construct the id belongs to, not the literal, so
        // that `--at` pointing anywhere inside the widget finds this row.
        line: lineInfo.getLocation(spans?.ownerStart ?? literal.offset).lineNumber,
        endLine: lineInfo.getLocation(spans?.ownerEnd ?? literal.end).lineNumber,
        widgetName: _baseName(widgetName),
        treatment: Treatment.existing,
        offset: literal.offset,
        end: literal.end,
        argsInsertAt: literal.offset,
        needsPrompt: false,
        paramName: paramName,
        helper: helper,
        nearbyText: nearbyText,
        spans: spans,
        originalId: literal.value,
        enclosingMethod: literal.thisOrAncestorOfType<MethodDeclaration>()?.name.lexeme,
        enclosingClass: literal.thisOrAncestorOfType<ClassDeclaration>()?.name.lexeme,
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Section roots
// ─────────────────────────────────────────────────────────────────────────────

/// Offsets of widgets that form the visible root of a build method.
///
/// This is what makes the tool instrument a `Container` that opens a panel
/// while leaving a `Container` used as a 13px colour swatch alone: neither is
/// in any role table, so only position in the tree distinguishes them.
Set<int> _findSectionRoots(CompilationUnit unit) {
  final Set<int> roots = <int>{};
  final _BuildMethodVisitor visitor = _BuildMethodVisitor();
  unit.accept(visitor);

  for (final MethodDeclaration method in visitor.buildMethods) {
    for (final Expression returned in _returnExpressions(method)) {
      final Expression? root = _descendToRoot(returned);
      if (root != null) roots.add(root.offset);
    }
  }
  return roots;
}

class _BuildMethodVisitor extends RecursiveAstVisitor<void> {
  final List<MethodDeclaration> buildMethods = <MethodDeclaration>[];

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    final String name = node.name.lexeme;
    final String returnType = node.returnType?.toSource() ?? '';
    if (name == 'build' || name.startsWith('_build') || returnType.startsWith('Widget')) {
      buildMethods.add(node);
    }
    super.visitMethodDeclaration(node);
  }
}

/// Expressions the method returns directly — not those returned from closures
/// nested inside it, which [_descendToRoot] reaches on its own.
List<Expression> _returnExpressions(MethodDeclaration method) {
  final FunctionBody body = method.body;
  if (body is ExpressionFunctionBody) return <Expression>[body.expression];
  if (body is BlockFunctionBody) {
    final _TopLevelReturnVisitor v = _TopLevelReturnVisitor();
    body.block.accept(v);
    return v.returns;
  }
  return <Expression>[];
}

class _TopLevelReturnVisitor extends RecursiveAstVisitor<void> {
  final List<Expression> returns = <Expression>[];

  @override
  void visitFunctionExpression(FunctionExpression node) {
    // Do not descend into closures; their returns belong to a builder.
  }

  @override
  void visitReturnStatement(ReturnStatement node) {
    final Expression? e = node.expression;
    if (e != null) returns.add(e);
    super.visitReturnStatement(node);
  }
}

/// Walks down through structural wrappers and builder closures to the first
/// widget that actually means something. Returns null when the chain ends in a
/// pass-through to another build method, or in something already instrumented.
Expression? _descendToRoot(Expression expression, {int depth = 0}) {
  if (depth > 24) return null;
  Expression e = expression;

  if (e is ParenthesizedExpression) {
    return _descendToRoot(e.expression, depth: depth + 1);
  }
  if (e is ConditionalExpression) {
    return _descendToRoot(e.thenExpression, depth: depth + 1);
  }

  final String? name = widgetNameOf(e);
  if (name == null) return null;

  // A call to another _build* helper instruments itself; do not double-wrap.
  if (e is MethodInvocation && e.target == null && !_startsUpper(name)) {
    return null;
  }
  if (name == 'SemanticHelper' || name.startsWith('SemanticHelper.')) return null;
  if (valueTypes.contains(_baseName(name))) return null;

  final ArgumentList? args = argumentListOf(e);
  if (args == null) return null;

  final String base = _baseName(name);
  if (structuralWidgets.contains(base)) {
    if (builderWidgets.contains(base)) {
      final Expression? built = _builderReturn(args);
      if (built != null) return _descendToRoot(built, depth: depth + 1);
    }
    final Expression? child = namedArgument(args, 'child');
    if (child != null) return _descendToRoot(child, depth: depth + 1);
    return null;
  }

  return e;
}

/// The expression a `builder:`-style closure returns.
Expression? _builderReturn(ArgumentList args) {
  for (final String key in <String>['builder', 'child', 'itemBuilder']) {
    final Expression? arg = namedArgument(args, key);
    if (arg is FunctionExpression) {
      final FunctionBody body = arg.body;
      if (body is ExpressionFunctionBody) return body.expression;
      if (body is BlockFunctionBody) {
        final _TopLevelReturnVisitor v = _TopLevelReturnVisitor();
        body.block.accept(v);
        if (v.returns.isNotEmpty) return v.returns.first;
      }
    } else if (arg != null && key == 'child') {
      return arg;
    }
  }
  return null;
}

// ─────────────────────────────────────────────────────────────────────────────
// Candidate collection
// ─────────────────────────────────────────────────────────────────────────────

class _Collector extends RecursiveAstVisitor<void> {
  _Collector({
    required this.filePath,
    required this.lineInfo,
    required this.facts,
    required this.sectionRoots,
    this.forceLines = const <int>{},
  });

  final String filePath;
  final LineInfo lineInfo;
  final ProjectFacts facts;
  final Set<int> sectionRoots;

  /// Lines the caller asked for explicitly. A widget starting on one of these
  /// is instrumented even where the rules would pass over it — the point of
  /// `--at` is that someone has already decided this widget matters.
  final Set<int> forceLines;

  final List<Candidate> candidates = <Candidate>[];

  @override
  void visitMethodInvocation(MethodInvocation node) {
    _consider(node);
    super.visitMethodInvocation(node);
  }

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    _consider(node);
    super.visitInstanceCreationExpression(node);
  }

  void _consider(Expression node) {
    final String? full = widgetNameOf(node);
    if (full == null) return;
    final String base = _baseName(full);
    if (!_startsUpper(base)) return;
    if (valueTypes.contains(base)) return;
    if (base == 'SemanticHelper') return;

    final ArgumentList? args = argumentListOf(node);
    if (args == null) return;

    if (_hasSemanticArgument(args)) return;
    if (_isChildOfSemanticHelper(node)) return;

    final String? param = facts.semanticParams[base];
    if (param != null) {
      _addInline(node, args, base, param);
      return;
    }

    // A requested line counts if the widget spans it, not only if it starts
    // there: a caller points at wherever their cursor sits, which is usually
    // an argument line in the middle of a multi-line widget.
    final int startLine = lineInfo.getLocation(node.offset).lineNumber;
    final int endLine = lineInfo.getLocation(node.end).lineNumber;
    final bool forced = forceLines.any(
      (int line) => line >= startLine && line <= endLine,
    );

    final Role? role = interactiveRoles[base];
    if (role != null) {
      if (!forced && !_hasHandler(base, args)) return;
      _addWrap(node, args, base, role);
      return;
    }

    // Structural widgets stay excluded even when forced: nobody wants an id on
    // a Padding, and span-matching would otherwise drag in every ancestor.
    if (forced && !structuralWidgets.contains(base)) {
      _addWrap(
        node,
        args,
        base,
        const Role('container', 'section', autoNameFromText: true),
      );
      return;
    }

    if (sectionRoots.contains(node.offset) &&
        !structuralWidgets.contains(base) &&
        !facts.projectWidgets.contains(base)) {
      _addWrap(
        node,
        args,
        base,
        const Role('container', 'section', autoNameFromText: true),
      );
    }
  }

  void _addInline(Expression node, ArgumentList args, String base, String param) {
    final String? auto = nameFromTextArgument(args);
    candidates.add(
      Candidate(
        filePath: filePath,
        line: lineInfo.getLocation(node.offset).lineNumber,
        endLine: lineInfo.getLocation(node.end).lineNumber,
        widgetName: base,
        treatment: Treatment.inline,
        offset: node.offset,
        end: node.end,
        argsInsertAt: args.leftParenthesis.end,
        needsPrompt: auto == null,
        paramName: param,
        autoName: auto,
        suggestion: _suggestion(node),
        enclosingMethod: _enclosingMethod(node),
        enclosingClass: _enclosingClass(node),
        nearbyText: _nearbyText(args),
      ),
    );
  }

  void _addWrap(Expression node, ArgumentList args, String base, Role role) {
    // A non-const helper call cannot be inserted inside a const expression.
    if (_inConstContext(node)) return;

    String helper = role.helper;
    Map<String, String> extra = _helperArgs(helper, args);

    final List<String> required = helperRequired[helper] ?? const <String>[];
    if (required.any((String r) => !extra.containsKey(r))) {
      helper = 'container';
      extra = _helperArgs(helper, args);
    }

    final String? auto = role.autoNameFromText ? nameFromTextArgument(args) : null;
    candidates.add(
      Candidate(
        filePath: filePath,
        line: lineInfo.getLocation(node.offset).lineNumber,
        endLine: lineInfo.getLocation(node.end).lineNumber,
        widgetName: base,
        treatment: Treatment.wrap,
        offset: node.offset,
        end: node.end,
        argsInsertAt: args.leftParenthesis.end,
        needsPrompt: auto == null,
        helper: helper,
        semanticType: facts.semanticTypes.resolve(role.semanticType),
        extraArgs: extra,
        autoName: auto,
        suggestion: _suggestion(node),
        enclosingMethod: _enclosingMethod(node),
        enclosingClass: _enclosingClass(node),
        nearbyText: _nearbyText(args),
      ),
    );
  }

  /// Fills every parameter the helper exposes for which the widget provides a
  /// source expression. Expressions are copied verbatim, never synthesized.
  Map<String, String> _helperArgs(String helper, ArgumentList args) {
    final Map<String, String> out = <String, String>{};
    for (final String param in helperParams[helper] ?? const <String>[]) {
      final List<String> sources = helperParamSources[param] ?? <String>[param];
      for (final String source in sources) {
        final Expression? value = namedArgument(args, source);
        if (value != null) {
          out[param] = value.toSource();
          break;
        }
      }
    }
    final List<String> params = helperParams[helper] ?? const <String>[];
    if (params.contains('label') && !out.containsKey('label')) {
      final Expression? text = textExpressionOf(args);
      if (text != null && isLikelyStringExpression(text)) {
        out['label'] = text.toSource();
      }
    }
    if (params.contains('isEnabled') &&
        !out.containsKey('isEnabled') &&
        _hasNullHandler(args)) {
      out['isEnabled'] = 'false';
    }
    return out;
  }

  bool _hasNullHandler(ArgumentList args) {
    for (final String key in <String>['onPressed', 'onTap']) {
      final Expression? handler = namedArgument(args, key);
      if (handler is NullLiteral) return true;
    }
    return false;
  }

  /// Interactive widgets with no handler are decorative; skip them.
  bool _hasHandler(String base, ArgumentList args) {
    const Set<String> needsHandler = <String>{
      'GestureDetector',
      'InkWell',
      'InkResponse',
    };
    if (!needsHandler.contains(base)) return true;
    for (final Expression a in args.arguments) {
      if (a is NamedExpression && a.name.label.name.startsWith('on')) return true;
    }
    return false;
  }

  bool _hasSemanticArgument(ArgumentList args) {
    for (final Expression a in args.arguments) {
      if (a is NamedExpression && semanticParamNames.contains(a.name.label.name)) {
        return true;
      }
    }
    return false;
  }

  bool _isChildOfSemanticHelper(Expression node) {
    final AstNode? named = node.parent;
    if (named is! NamedExpression || named.name.label.name != 'child') return false;
    final AstNode? call = named.parent?.parent;
    if (call is MethodInvocation) {
      return call.target?.toSource() == 'SemanticHelper';
    }
    return false;
  }

  bool _inConstContext(AstNode node) {
    AstNode? current = node.parent;
    while (current != null) {
      if (current is InstanceCreationExpression && current.isConst) return true;
      if (current is TypedLiteral && current.constKeyword != null) return true;
      if (current is VariableDeclarationList && current.isConst) return true;
      if (current is MethodDeclaration || current is FunctionDeclaration) break;
      current = current.parent;
    }
    return false;
  }

  String? _suggestion(AstNode node) =>
      nameFromMethod(_enclosingMethod(node)) ?? nameFromClass(_enclosingClass(node));

  String? _enclosingMethod(AstNode node) =>
      node.thisOrAncestorOfType<MethodDeclaration>()?.name.lexeme;

  String? _enclosingClass(AstNode node) =>
      node.thisOrAncestorOfType<ClassDeclaration>()?.name.lexeme;

  String? _nearbyText(ArgumentList args) {
    for (final String key in namingArgs) {
      final Expression? value = namedArgument(args, key);
      if (value != null) return value.toSource();
    }
    return null;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Shared AST helpers
// ─────────────────────────────────────────────────────────────────────────────

/// The constructor or factory name behind a widget expression.
///
/// Unresolved parsing reports `Container(...)` as a [MethodInvocation], so both
/// node types have to be handled.
String? widgetNameOf(Expression e) {
  if (e is InstanceCreationExpression) return e.constructorName.toSource();
  if (e is MethodInvocation) {
    final Expression? target = e.target;
    if (target == null) return e.methodName.name;
    if (target is SimpleIdentifier) return '${target.name}.${e.methodName.name}';
    return null;
  }
  return null;
}

ArgumentList? argumentListOf(Expression e) {
  if (e is InstanceCreationExpression) return e.argumentList;
  if (e is MethodInvocation) return e.argumentList;
  return null;
}

String _baseName(String name) {
  final int dot = name.indexOf('.');
  final String head = dot == -1 ? name : name.substring(0, dot);
  final int lt = head.indexOf('<');
  return lt == -1 ? head : head.substring(0, lt);
}

bool _startsUpper(String s) =>
    s.isNotEmpty && s[0].toUpperCase() == s[0] && s[0] != '_';
