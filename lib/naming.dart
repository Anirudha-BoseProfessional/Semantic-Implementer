/// Derives semantic id strings, and keeps them unique across a run.
library;

import 'package:analyzer/dart/ast/ast.dart';

import 'rules.dart';

/// Converts an identifier or sentence into a `snake_case` semantic id.
///
/// `filterSelectAll` -> `filter_select_all`, `'No zones yet'` -> `no_zones_yet`.
String slugify(String input) {
  final String spaced = input
      .replaceAllMapped(
        RegExp(r'(?<=[a-z0-9])(?=[A-Z])'),
        (Match _) => '_',
      )
      .replaceAllMapped(
        RegExp(r'(?<=[A-Z])(?=[A-Z][a-z])'),
        (Match _) => '_',
      );
  return spaced
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
      .replaceAll(RegExp(r'_{2,}'), '_')
      .replaceAll(RegExp(r'^_+|_+$'), '');
}

/// Strips the `_build` prefix from a builder method name.
/// `_buildZoneContent` -> `zone_content`.
String? nameFromMethod(String? methodName) {
  if (methodName == null) return null;
  String n = methodName;
  if (n.startsWith('_')) n = n.substring(1);
  if (n.startsWith('build') && n.length > 5) n = n.substring(5);
  if (n == 'build' || n.isEmpty) return null;
  final String slug = slugify(n);
  return slug.isEmpty ? null : slug;
}

/// Strips private/State decoration from a class name.
/// `_FilterSectionState` -> `filter_section`.
String? nameFromClass(String? className) {
  if (className == null) return null;
  String n = className;
  if (n.startsWith('_')) n = n.substring(1);
  if (n.endsWith('State') && n.length > 5) {
    n = n.substring(0, n.length - 5);
  }
  final String slug = slugify(n);
  return slug.isEmpty ? null : slug;
}

/// The expression carrying a widget's user-visible text, if it has one.
///
/// Looks at named arguments (`text:`, `label:`, `title:`), then a leading
/// positional string — `Text('No zones yet')` carries its label that way —
/// then a `child:` holding a text widget, which is how a Flutter button
/// labels itself.
Expression? textExpressionOf(ArgumentList args, {int depth = 0}) {
  for (final String key in namingArgs) {
    final Expression? value = namedArgument(args, key);
    if (value != null) return value;
  }

  for (final Expression a in args.arguments) {
    if (a is NamedExpression) continue;
    if (a is StringLiteral) return a;
    break;
  }

  if (depth < 2) {
    final Expression? child = namedArgument(args, 'child');
    if (child != null) {
      final String? name = _calleeName(child);
      if (name != null && textWidgets.contains(name)) {
        final ArgumentList? inner = _argumentsOf(child);
        if (inner != null) return textExpressionOf(inner, depth: depth + 1);
      }
    }
  }
  return null;
}

/// Pulls a name out of a text-bearing argument, if the widget has one.
///
/// Handles string literals (`'No zones yet'`), localization accessors
/// (`localization.filterSelectAll`) and localization calls with arguments
/// (`localization.filterDeleteFloorDescription(floor.name)`).
String? nameFromTextArgument(ArgumentList args) {
  final Expression? text = textExpressionOf(args);
  if (text == null) return null;
  final String? derived = _fromExpression(text);
  return (derived == null || derived.isEmpty) ? null : derived;
}

/// Whether [e] can safely be copied into a `String?` helper argument.
///
/// Naming only slugifies an expression, so anything goes there — but emitting
/// one as `label:` needs it to actually be a string. A constructor call is the
/// giveaway for a Widget that would fail to type-check.
bool isLikelyStringExpression(Expression e) {
  if (e is StringLiteral) return true;
  if (e is InstanceCreationExpression) return false;
  if (e is SimpleIdentifier || e is PrefixedIdentifier || e is PropertyAccess) {
    return true;
  }
  if (e is MethodInvocation) {
    final String name = e.methodName.name;
    return name.isNotEmpty && name[0].toLowerCase() == name[0];
  }
  if (e is ConditionalExpression) {
    return isLikelyStringExpression(e.thenExpression) &&
        isLikelyStringExpression(e.elseExpression);
  }
  return false;
}

String? _calleeName(Expression e) {
  if (e is InstanceCreationExpression) {
    final String source = e.constructorName.toSource();
    final int dot = source.indexOf('.');
    return dot == -1 ? source : source.substring(0, dot);
  }
  if (e is MethodInvocation && e.target == null) return e.methodName.name;
  return null;
}

ArgumentList? _argumentsOf(Expression e) {
  if (e is InstanceCreationExpression) return e.argumentList;
  if (e is MethodInvocation) return e.argumentList;
  return null;
}

String? _fromExpression(Expression e) {
  // `title: Text('Add zone')` — reach through the text widget to its string,
  // otherwise the constructor name slugifies to a useless `text`.
  final String? callee = _calleeName(e);
  if (callee != null && textWidgets.contains(callee)) {
    final ArgumentList? inner = _argumentsOf(e);
    if (inner != null) {
      final Expression? nested = textExpressionOf(inner, depth: 1);
      if (nested != null) return _fromExpression(nested);
    }
  }
  if (e is SimpleStringLiteral) return slugify(e.value);
  if (e is StringInterpolation) {
    // Name from the literal parts only: `'Count: ${items.length}'` -> `count`.
    final StringBuffer literal = StringBuffer();
    for (final InterpolationElement element in e.elements) {
      if (element is InterpolationString) literal.write(element.value);
    }
    final String slug = slugify(literal.toString());
    return slug.isEmpty ? null : slug;
  }
  if (e is AdjacentStrings) {
    final StringLiteral first = e.strings.first;
    if (first is SimpleStringLiteral) return slugify(first.value);
    return null;
  }
  if (e is PrefixedIdentifier) return slugify(e.identifier.name);
  if (e is PropertyAccess) return slugify(e.propertyName.name);
  if (e is MethodInvocation) return slugify(e.methodName.name);
  if (e is SimpleIdentifier) return slugify(e.name);
  // A conditional such as `state.filterMode ? a : b` — take the first branch,
  // since both sides name the same control.
  if (e is ConditionalExpression) return _fromExpression(e.thenExpression);
  return null;
}

/// Returns the expression for named argument [name], or null.
Expression? namedArgument(ArgumentList args, String name) {
  for (final Expression a in args.arguments) {
    if (a is NamedExpression && a.name.label.name == name) return a.expression;
  }
  return null;
}

/// Tracks which ids a run has already handed out, so no two widgets collide.
class IdRegistry {
  final Set<String> _used = <String>{};

  /// Registers [candidate], suffixing `_2`, `_3`, ... if it is taken.
  String claim(String candidate) {
    final String base = candidate.isEmpty ? 'widget' : candidate;
    if (_used.add(base)) return base;
    int n = 2;
    while (!_used.add('${base}_$n')) {
      n++;
    }
    return '${base}_$n';
  }

  /// Marks an id already present in the source as taken.
  void reserve(String id) => _used.add(id);

  /// Gives an id back, so renaming a widget frees the name it held.
  void release(String id) => _used.remove(id);
}
