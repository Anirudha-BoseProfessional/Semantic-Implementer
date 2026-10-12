/// Decision tables: which widgets get instrumented, how, and with which
/// `SemanticHelper` method.
library;

/// How a widget expression should be treated.
enum Treatment {
  /// Leave it alone.
  skip,

  /// Widget accepts a semantic id argument directly — add it.
  inline,

  /// Wrap the expression in a `SemanticHelper.*` call.
  wrap,

  /// Already carries a string-literal id. Listed so it can be renamed; the
  /// source is only touched if the id actually changes.
  existing,
}

/// Structural / builder widgets that carry no meaning for a test harness.
/// They are transparent: the tool descends through them looking for a real
/// widget, but never instruments them.
const Set<String> structuralWidgets = <String>{
  'Row', 'Column', 'Stack', 'Wrap', 'Flex', 'ListBody',
  'SizedBox', 'Padding', 'Center', 'Align', 'FractionallySizedBox',
  'Expanded', 'Flexible', 'Spacer', 'Positioned', 'PositionedDirectional',
  'Divider', 'VerticalDivider',
  'ClipRect', 'ClipRRect', 'ClipOval', 'ClipPath',
  'Opacity', 'Transform', 'FittedBox', 'AspectRatio', 'IntrinsicWidth',
  'IntrinsicHeight', 'ConstrainedBox', 'LimitedBox', 'OverflowBox',
  'Offstage', 'Visibility', 'SafeArea', 'RepaintBoundary',
  'Builder', 'LayoutBuilder', 'StatefulBuilder', 'OrientationBuilder',
  'AnimatedBuilder', 'ValueListenableBuilder', 'FutureBuilder', 'StreamBuilder',
  'BlocBuilder', 'BlocProvider', 'MultiBlocProvider', 'BlocListener',
  'MultiBlocListener', 'BlocConsumer', 'BlocSelector', 'RepositoryProvider',
  'Consumer', 'Provider', 'ChangeNotifierProvider', 'MultiProvider', 'Selector',
  'ScrollConfiguration', 'SingleChildScrollView', 'Scrollbar',
  'NotificationListener', 'ListView', 'GridView', 'PageView', 'CustomScrollView',
  'MouseRegion', 'TapRegion', 'IgnorePointer', 'AbsorbPointer',
  'Material', 'MediaQuery', 'Theme', 'DefaultTextStyle', 'Directionality',
  'Nested',
};

/// Widgets that are transparent but whose child lives behind a builder closure
/// rather than a `child:` argument.
const Set<String> builderWidgets = <String>{
  'Builder', 'LayoutBuilder', 'StatefulBuilder', 'OrientationBuilder',
  'AnimatedBuilder', 'ValueListenableBuilder', 'FutureBuilder', 'StreamBuilder',
  'BlocBuilder', 'BlocConsumer', 'BlocSelector', 'Consumer', 'Selector',
  'BlocProvider', 'MultiBlocProvider', 'RepositoryProvider', 'Provider',
  'ChangeNotifierProvider', 'MultiProvider',
};

/// Constructors that build values, not widgets. Never instrumented, and the
/// tool does not descend into them looking for section roots.
const Set<String> valueTypes = <String>{
  'EdgeInsets', 'EdgeInsetsDirectional', 'BorderRadius', 'Radius', 'Border',
  'BorderSide', 'BoxDecoration', 'BoxShadow', 'BoxConstraints', 'Offset',
  'Size', 'Rect', 'Color', 'Colors', 'TextStyle', 'TextTheme', 'Duration',
  'Key', 'ValueKey', 'GlobalKey', 'ObjectKey', 'UniqueKey',
  'MaterialPageRoute', 'PageRouteBuilder', 'RouteSettings',
  'LinearGradient', 'RadialGradient', 'SweepGradient', 'Tween', 'ColorTween',
  'CurvedAnimation', 'AlwaysStoppedAnimation', 'TextEditingController',
  'ScrollController', 'PageController', 'FocusNode', 'Matrix4',
  'InputDecoration', 'OutlineInputBorder', 'UnderlineInputBorder',
  'SystemMouseCursors', 'OrdinalSortKey', 'TextSelection', 'TextRange',
  'DateTime', 'Uri', 'RegExp', 'Exception', 'Error', 'Future', 'Stream',
  'List', 'Map', 'Set', 'String', 'int', 'double', 'bool',
};

/// A role assignment for a widget the tool recognises.
class Role {
  const Role(this.helper, this.semanticType, {this.autoNameFromText = false});

  /// `SemanticHelper` method name.
  final String helper;

  /// Desired `SemanticTypes` member (resolved against what the project has).
  final String semanticType;

  /// Whether this widget usually carries text that can name it without asking.
  final bool autoNameFromText;
}

/// Widgets with a known interactive role.
const Map<String, Role> interactiveRoles = <String, Role>{
  'GestureDetector': Role('button', 'button', autoNameFromText: true),
  'InkWell': Role('button', 'button', autoNameFromText: true),
  'InkResponse': Role('button', 'button', autoNameFromText: true),
  'ElevatedButton': Role('button', 'button', autoNameFromText: true),
  'TextButton': Role('button', 'button', autoNameFromText: true),
  'OutlinedButton': Role('button', 'button', autoNameFromText: true),
  'FilledButton': Role('button', 'button', autoNameFromText: true),
  'IconButton': Role('button', 'button'),
  'FloatingActionButton': Role('button', 'button'),
  'CupertinoButton': Role('button', 'button', autoNameFromText: true),
  'Checkbox': Role('toggle', 'checkbox'),
  'CheckboxListTile': Role('toggle', 'checkbox', autoNameFromText: true),
  'Switch': Role('toggle', 'toggle'),
  'SwitchListTile': Role('toggle', 'toggle', autoNameFromText: true),
  'Radio': Role('radio', 'radio'),
  'RadioListTile': Role('radio', 'radio', autoNameFromText: true),
  'Slider': Role('slider', 'slider'),
  'RangeSlider': Role('rangeSlider', 'slider'),
  'TextField': Role('textInput', 'textField'),
  'TextFormField': Role('textInput', 'textField'),
  'DropdownButton': Role('dropdown', 'dropdown'),
  'DropdownButtonFormField': Role('dropdown', 'dropdown'),
  'PopupMenuButton': Role('popupButton', 'button'),
  'Image': Role('image', 'image'),
  'SvgPicture': Role('image', 'image'),
  'Text': Role('staticText', 'text', autoNameFromText: true),
  'SelectableText': Role('staticText', 'text', autoNameFromText: true),
  'RichText': Role('staticText', 'text'),
  'Table': Role('table', 'table'),
  'DataTable': Role('table', 'table'),
};

/// Fallback map of widgets known to accept a semantic id argument, used when
/// the widget's own source is not on any scanned path.
///
/// `FusionFlatContainer` spells it `semanticsId`, with the `s` — the
/// inconsistency is why this is a map and not a set.
const Map<String, String> seedSemanticParams = <String, String>{
  'FusionAppText': 'semanticId',
  'FusionAppButton': 'semanticId',
  'FusionCheckbox': 'semanticId',
  'FusionIcon': 'semanticId',
  'FusionKebabPopup': 'semanticId',
  'DialogBox': 'semanticId',
  'FusionFlatContainer': 'semanticsId',
};

/// Argument names on a widget that can supply a semantic id, in priority order.
const List<String> semanticParamNames = <String>[
  'semanticId',
  'semanticsId',
  'testId',
];

/// Widgets whose whole job is to display text, so a parent holding one in its
/// `child:` can borrow that text as its own name.
const Set<String> textWidgets = <String>{
  'Text',
  'SelectableText',
  'RichText',
  'FusionAppText',
};

/// Arguments whose value can name a widget without asking the user.
const List<String> namingArgs = <String>[
  'text',
  'label',
  'title',
  'labelText',
  'hintText',
];

/// Parameters each `SemanticHelper` method accepts, beyond `testId`/`child`.
/// Drives how much metadata gets filled in on a wrap.
const Map<String, List<String>> helperParams = <String, List<String>>{
  'button': <String>['label', 'isEnabled', 'isSelected'],
  'container': <String>[
    'label', 'value', 'isEnabled', 'isChecked', 'isSelected',
    'explicitChildNodes',
  ],
  'image': <String>['label', 'explicitChildNodes'],
  'toggle': <String>['value', 'label'],
  'radio': <String>['value', 'label'],
  'radioGroup': <String>['label', 'value'],
  'listItem': <String>['index', 'label'],
  'formControl': <String>['label', 'hint'],
  'staticText': <String>['label', 'value'],
  'textInput': <String>[
    'label', 'readonly', 'enabled', 'focused', 'value', 'live',
  ],
  'dropdown': <String>['label', 'value'],
  'popupButton': <String>['enabled', 'blur'],
  'table': <String>['enabled', 'blur', 'value'],
  'slider': <String>['label', 'value', 'minValue', 'maxValue'],
  'rangeSlider': <String>[
    'label', 'lowerValue', 'upperValue', 'minValue', 'maxValue',
  ],
};

/// Parameters a helper requires beyond `testId` and `child`. If the tool cannot
/// source these from the widget, it must fall back to a helper that does not
/// need them — emitting a call with a missing required argument is a build
/// break, and a less specific node beats a broken one.
const Map<String, List<String>> helperRequired = <String, List<String>>{
  'toggle': <String>['value'],
  'radio': <String>['value'],
  'listItem': <String>['index'],
};

/// Maps an argument name on the source widget to a helper parameter name.
/// Consulted per helper against [helperParams].
const Map<String, List<String>> helperParamSources = <String, List<String>>{
  // `title` is intentionally absent: in Flutter it usually holds a Widget, and
  // copying one into the helper's `String? label` would not type-check.
  'label': <String>['label', 'text', 'labelText'],
  'value': <String>['value'],
  'isEnabled': <String>['enabled', 'isEnabled'],
  'enabled': <String>['enabled', 'isEnabled'],
  'isChecked': <String>['checked', 'isChecked'],
  'isSelected': <String>['selected', 'isSelected'],
  'hint': <String>['hint', 'hintText'],
  'readonly': <String>['readOnly', 'readonly'],
  'focused': <String>['focused', 'autofocus'],
  'minValue': <String>['min', 'minValue'],
  'maxValue': <String>['max', 'maxValue'],
  'lowerValue': <String>['start', 'lowerValue'],
  'upperValue': <String>['end', 'upperValue'],
  'index': <String>['index'],
};

/// Known `SemanticTypes` members, discovered from the target project.
///
/// Only `container`, `section` and `button` are confirmed to exist from the
/// reference files, so an unknown desired type degrades to something real
/// rather than producing a name that will not compile.
class SemanticTypesCatalog {
  SemanticTypesCatalog(Set<String> discovered)
      : members = <String>{...discovered, ...confirmed};

  static const Set<String> confirmed = <String>{
    'container',
    'section',
    'button',
  };

  final Set<String> members;

  /// Returns [desired] if the project defines it, else the closest safe member.
  String resolve(String desired) {
    if (members.contains(desired)) return desired;
    const Map<String, String> fallbacks = <String, String>{
      'checkbox': 'button',
      'toggle': 'button',
      'radio': 'button',
      'dropdown': 'button',
      'slider': 'container',
      'textField': 'container',
      'text': 'container',
      'image': 'container',
      'table': 'container',
    };
    final String? alt = fallbacks[desired];
    if (alt != null && members.contains(alt)) return alt;
    return 'container';
  }
}
