// Flutter / fusion_lib stand-ins so the fixture compiles with plain `dart
// analyze`, no Flutter toolchain required.
//
// This directory is deliberately NOT the tool's target. Scanning it would
// register `Container`, `Row` and friends as project-declared widgets, which
// would suppress exactly the behaviour the fixture exists to exercise.

class Widget {
  const Widget({this.key});
  final Object? key;
}

class StatelessWidget extends Widget {
  const StatelessWidget({super.key});
  Widget build(BuildContext context) => const Widget();
}

class StatefulWidget extends Widget {
  const StatefulWidget({super.key});
}

class State<T> {
  Widget build(BuildContext context) => const Widget();
}

class BuildContext {
  const BuildContext();
}

class VoidCallback {
  const VoidCallback();
}

// ── Value types (never instrumented) ────────────────────────────────────────

class EdgeInsets {
  const EdgeInsets.all(this.value);
  const EdgeInsets.only({this.value = 0});
  final double value;
}

class BorderRadius {
  const BorderRadius.circular(this.radius);
  final double radius;
}

class BoxDecoration {
  const BoxDecoration({this.color, this.borderRadius});
  final Object? color;
  final BorderRadius? borderRadius;
}

class TextStyle {
  const TextStyle({this.color, this.fontSize});
  final Object? color;
  final double? fontSize;
}

class Duration {
  const Duration({this.seconds = 0});
  final int seconds;
}

class Color {
  const Color(this.value);
  final int value;
}

// ── Structural widgets ──────────────────────────────────────────────────────

class Container extends Widget {
  const Container({
    this.color,
    this.padding,
    this.margin,
    this.decoration,
    this.width,
    this.height,
    this.child,
  });
  final Object? color;
  final EdgeInsets? padding;
  final EdgeInsets? margin;
  final BoxDecoration? decoration;
  final double? width;
  final double? height;
  final Widget? child;
}

class Column extends Widget {
  const Column({this.children = const <Widget>[]});
  final List<Widget> children;
}

class Row extends Widget {
  const Row({this.children = const <Widget>[]});
  final List<Widget> children;
}

class Stack extends Widget {
  const Stack({this.children = const <Widget>[]});
  final List<Widget> children;
}

class SizedBox extends Widget {
  const SizedBox({this.width, this.height, this.child});
  final double? width;
  final double? height;
  final Widget? child;
}

class Padding extends Widget {
  const Padding({required this.padding, required this.child});
  final EdgeInsets padding;
  final Widget child;
}

class Center extends Widget {
  const Center({required this.child});
  final Widget child;
}

class Expanded extends Widget {
  const Expanded({required this.child, this.flex = 1});
  final Widget child;
  final int flex;
}

class Flexible extends Widget {
  const Flexible({required this.child, this.flex = 1});
  final Widget child;
  final int flex;
}

class Divider extends Widget {
  const Divider({this.height});
  final double? height;
}

class ClipRect extends Widget {
  const ClipRect({required this.child});
  final Widget child;
}

class SingleChildScrollView extends Widget {
  const SingleChildScrollView({required this.child});
  final Widget child;
}

class ListView extends Widget {
  const ListView.builder({
    required this.itemCount,
    required this.itemBuilder,
    this.shrinkWrap = false,
  });
  final int itemCount;
  final Widget Function(BuildContext, int) itemBuilder;
  final bool shrinkWrap;
}

class MouseRegion extends Widget {
  const MouseRegion({required this.child});
  final Widget child;
}

class IgnorePointer extends Widget {
  const IgnorePointer({required this.child});
  final Widget child;
}

class Builder extends Widget {
  const Builder({required this.builder});
  final Widget Function(BuildContext) builder;
}

class LayoutBuilder extends Widget {
  const LayoutBuilder({required this.builder});
  final Widget Function(BuildContext, Object) builder;
}

class BlocBuilder<V, S> extends Widget {
  const BlocBuilder({required this.builder, this.buildWhen});
  final Widget Function(BuildContext, S) builder;
  final bool Function(S, S)? buildWhen;
}

// ── Interactive widgets ─────────────────────────────────────────────────────

class GestureDetector extends Widget {
  const GestureDetector({this.onTap, this.onVerticalDragUpdate, required this.child});
  final void Function()? onTap;
  final void Function(double)? onVerticalDragUpdate;
  final Widget child;
}

class InkWell extends Widget {
  const InkWell({this.onTap, required this.child});
  final void Function()? onTap;
  final Widget child;
}

class TextButton extends Widget {
  const TextButton({required this.onPressed, required this.child});
  final void Function()? onPressed;
  final Widget child;
}

class ElevatedButton extends Widget {
  const ElevatedButton({required this.onPressed, required this.child});
  final void Function()? onPressed;
  final Widget child;
}

class IconButton extends Widget {
  const IconButton({required this.onPressed, required this.icon});
  final void Function()? onPressed;
  final Widget icon;
}

class Checkbox extends Widget {
  const Checkbox({required this.value, this.onChanged, this.enabled});
  final bool value;
  final void Function(bool?)? onChanged;
  final bool? enabled;
}

class Switch extends Widget {
  const Switch({required this.value, this.onChanged});
  final bool value;
  final void Function(bool)? onChanged;
}

class Radio<T> extends Widget {
  const Radio({required this.value, this.groupValue, this.onChanged});
  final T value;
  final T? groupValue;
  final void Function(T?)? onChanged;
}

class Slider extends Widget {
  const Slider({required this.value, this.min, this.max, this.onChanged, this.label});
  final double value;
  final double? min;
  final double? max;
  final void Function(double)? onChanged;
  final String? label;
}

class RangeSlider extends Widget {
  const RangeSlider({required this.start, required this.end, this.min, this.max});
  final double start;
  final double end;
  final double? min;
  final double? max;
}

class TextField extends Widget {
  const TextField({
    this.hintText,
    this.readOnly = false,
    this.enabled,
    this.autofocus = false,
    this.controller,
  });
  final String? hintText;
  final bool readOnly;
  final bool? enabled;
  final bool autofocus;
  final Object? controller;
}

class DropdownButton<T> extends Widget {
  const DropdownButton({required this.items, this.value, this.onChanged});
  final List<T> items;
  final T? value;
  final void Function(T?)? onChanged;
}

class PopupMenuButton<T> extends Widget {
  const PopupMenuButton({required this.itemBuilder, this.enabled = true});
  final List<T> Function(BuildContext) itemBuilder;
  final bool enabled;
}

class Image extends Widget {
  const Image.asset(this.name, {this.label});
  final String name;
  final String? label;
}

class Table extends Widget {
  const Table({this.children = const <Widget>[], this.enabled = true});
  final List<Widget> children;
  final bool enabled;
}

class Text extends Widget {
  const Text(this.data, {this.style});
  final String data;
  final TextStyle? style;
}

class RichText extends Widget {
  const RichText({required this.text});
  final Widget text;
}

class Icon extends Widget {
  const Icon(this.name);
  final String name;
}

// ── fusion_lib stand-ins ────────────────────────────────────────────────────

class FusionAppText extends Widget {
  const FusionAppText({required this.text, this.semanticId, this.style, this.maxLine});
  final String text;
  final String? semanticId;
  final TextStyle? style;
  final int? maxLine;
}

class FusionAppButton extends Widget {
  const FusionAppButton({
    required this.text,
    required this.onPressed,
    this.semanticId,
    this.showPrefixIcon = false,
  });
  final String text;
  final void Function()? onPressed;
  final String? semanticId;
  final bool showPrefixIcon;
}

class FusionCheckbox extends Widget {
  const FusionCheckbox({required this.value, required this.onChanged, this.semanticId});
  final bool value;
  final void Function() onChanged;
  final String? semanticId;
}

class FusionIcon extends Widget {
  const FusionIcon.icon(this.name, {this.semanticId, this.color});
  final String name;
  final String? semanticId;
  final Object? color;
}

class FusionKebabPopup extends Widget {
  const FusionKebabPopup({required this.items, this.semanticId});
  final List<String> items;
  final String? semanticId;
}

class DialogBox extends Widget {
  const DialogBox({
    required this.title,
    required this.description,
    this.semanticId,
  });
  final String title;
  final String description;
  final String? semanticId;
}

/// Note the spelling: `semanticsId`, not `semanticId`.
class FusionFlatContainer extends Widget {
  const FusionFlatContainer({
    required this.child,
    this.width,
    this.borderRadius,
    this.semanticsId,
  });
  final Widget child;
  final double? width;
  final double? borderRadius;
  final String? semanticsId;
}

/// Carries its label as a Widget in `title:`, the shape that would break a
/// naive `label:` fill.
class SectionTile extends Widget {
  const SectionTile({required this.title, required this.child, this.onTap});
  final Widget title;
  final Widget child;
  final void Function()? onTap;
}

/// A custom widget declared outside the target: not a project widget from the
/// tool's point of view, so it behaves like any unknown third-party widget.
class PropertyTextField extends Widget {
  const PropertyTextField({required this.controller, this.maxLength, this.hintText});
  final Object controller;
  final int? maxLength;
  final String? hintText;
}

// ── Localization stand-in ───────────────────────────────────────────────────

class AppLocalizations {
  const AppLocalizations();
  String get filterSelectAll => 'Select All';
  String get filterAdd => 'Add';
  String get filterDone => 'Done';
  String get filterFilter => 'Filter';
  String get filterNoZonesYet => 'No zones yet';
  String filterDeleteFloorDescription(String name) => 'Delete $name?';
}

const AppLocalizations localization = AppLocalizations();

// ── Semantics ───────────────────────────────────────────────────────────────

class SemanticTypes {
  static const String container = 'container';
  static const String section = 'section';
  static const String button = 'button';
  static const String checkbox = 'checkbox';
  static const String toggle = 'toggle';
  static const String radio = 'radio';
  static const String dropdown = 'dropdown';
  static const String slider = 'slider';
  static const String textField = 'text_field';
  static const String text = 'text';
  static const String image = 'image';
  static const String table = 'table';
}

class SemanticHelper {
  static String createTestId(String type, String identifier) =>
      '${type}_${identifier.replaceAll(' ', '_').toLowerCase()}';

  static Widget button({
    required String testId,
    required Widget child,
    String? label,
    bool isEnabled = true,
    bool isSelected = false,
  }) => child;

  static Widget slider({
    required String testId,
    String? label,
    num? value,
    num? minValue,
    num? maxValue,
    required Widget child,
  }) => child;

  static Widget rangeSlider({
    required String testId,
    String? label,
    num? lowerValue,
    num? upperValue,
    num? minValue,
    num? maxValue,
    required Widget child,
  }) => child;

  static Widget container({
    required String testId,
    required Widget child,
    bool explicitChildNodes = false,
    String? label,
    String? value,
    bool? isEnabled,
    bool? isChecked,
    bool? isSelected,
  }) => child;

  static Widget image({
    required String testId,
    required Widget child,
    bool explicitChildNodes = false,
    String? label,
  }) => child;

  static Widget toggle({
    required String testId,
    required bool value,
    required Widget child,
    String? label,
    bool excludeChildSemantics = true,
  }) => child;

  static Widget radio({
    required String testId,
    required bool value,
    required Widget child,
    String? label,
    bool excludeChildSemantics = true,
  }) => child;

  static Widget radioGroup({
    required String testId,
    required Widget child,
    String? label,
    String? value,
  }) => child;

  static Widget listItem({
    required String testId,
    required Widget child,
    required int index,
    String? label,
  }) => child;

  static Widget formControl({
    required String testId,
    required Widget child,
    String? label,
    String? hint,
  }) => child;

  static Widget staticText({
    required String testId,
    required Widget child,
    String? label,
    String? value,
  }) => child;

  static Widget textInput({
    required String testId,
    required Widget child,
    String? label,
    bool? readonly,
    bool? enabled,
    bool? focused,
    String? value,
    bool? live,
  }) => child;

  static Widget dropdown({
    required String testId,
    required Widget child,
    String? label,
    String? value,
  }) => child;

  static Widget popupButton({
    required String testId,
    required Widget child,
    bool? enabled,
    bool? blur,
  }) => child;

  static Widget table({
    required String testId,
    required Widget child,
    bool? enabled,
    bool? blur,
    String? value,
  }) => child;
}
