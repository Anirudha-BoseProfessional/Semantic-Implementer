// Exercises every branch of the semantic implementer.
//
// Each case is labelled with what the tool is expected to do. Run:
//   dart run bin/semantic_implementer.dart --dry-run --auto test_fixture/input
// then compare the summary against these comments, and `dart analyze
// test_fixture` to prove the rewritten output still compiles.

import '../stubs/stubs.dart';

// ─────────────────────────────────────────────────────────────────────────────
// A. PATTERN A — widgets that accept a semantic id argument directly
// ─────────────────────────────────────────────────────────────────────────────

class InlineCases extends StatelessWidget {
  const InlineCases({super.key, this.isDone = false});

  final bool isDone;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        // A1 inline, named from the literal -> `save_changes`
        const FusionAppText(semanticId: 'testing', text: 'Save changes'),

        // A2 inline, named from the localization key -> `filter_select_all`
        FusionAppText(text: localization.filterSelectAll),

        // A3 inline, named from a localization CALL -> `filter_delete_floor_description`
        FusionAppText(text: localization.filterDeleteFloorDescription('L1')),

        // A4 inline from the then-branch of a conditional -> `filter_done`
        FusionAppText(text: isDone ? localization.filterDone : localization.filterFilter),

        // A5 SKIP — already carries an id
        const FusionAppText(text: 'Untouched', semanticId: 'already_named'),

        // A6 inline on a NAMED constructor -> `semanticId` on FusionIcon.icon
        const FusionIcon.icon('plus'),

        // A7 inline works inside a const context (a literal argument is const)
        const Padding(
          padding: EdgeInsets.all(8),
          child: FusionAppText(text: 'Const safe'),
        ),

        // A8 the `semanticsId` spelling trap — must NOT emit `semanticId`
        FusionFlatContainer( 
          width: 308,
          child: const FusionAppText(text: 'Docked'),
        ),

        // A9 inline, named from the title literal -> `delete_floor`
        const DialogBox(title: 'Delete floor', description: 'Are you sure?'),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// B. PATTERN B — role wrapping
// ─────────────────────────────────────────────────────────────────────────────

class RoleCases extends StatelessWidget {
  const RoleCases({super.key, this.checked = false, this.volume = 0.5});

  final bool checked;
  final double volume;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        // B1 button, named by borrowing its child's text -> `select_all`
        GestureDetector(
          onTap: () {},
          child: const FusionAppText(semanticId: 'select_all', text: 'Select all'),
        ),

        // B2 SKIP — a GestureDetector with no handler is decorative
        const GestureDetector(child: Text('Not interactive')),

        // B3 toggle; required `value:` sourced from the widget
        Checkbox(value: checked, onChanged: (bool? v) {}),

        // B4 toggle on a Switch
        Switch(value: checked, onChanged: (bool v) {}),

        // B5 radio; required `value:` present, so radio is kept
        Radio<bool>(value: checked, groupValue: true, onChanged: (bool? v) {}),

        // B6 slider; label/value/minValue/maxValue all filled from the widget
        Slider(value: volume, min: 0, max: 10, label: 'Volume', onChanged: (double v) {}),

        // B7 rangeSlider; lowerValue/upperValue from start/end
        const RangeSlider(start: 2, end: 8, min: 0, max: 10),

        // B8 textInput; hint is not a param, but readonly/enabled/focused are
        const TextField(hintText: 'Search zones', readOnly: true, autofocus: true),

        // B9 dropdown
        DropdownButton<String>(items: const <String>['A', 'B'], onChanged: (String? v) {}),

        // B10 popupButton; `enabled` filled
        PopupMenuButton<String>(enabled: false, itemBuilder: (BuildContext c) => const <String>[]),

        // B11 image
        const Image.asset('assets/logo.png'),

        // B12 table; `enabled` filled
        const Table(enabled: true),

        // B13 staticText, named from a POSITIONAL string -> `no_zones_yet`
        const Text('No zones yet'),

        // B14 button + `isEnabled: false` derived from `onPressed: null`
        TextButton(onPressed: null, child: const Text('Add zone')),

        // B15 button with no text anywhere -> prompts, suggestion from `build`
        IconButton(onPressed: () {}, icon: const Icon('trash')),

        // B16 inline wins over wrapping: FusionAppButton has its own id param
        FusionAppButton(text: localization.filterAdd, onPressed: () {}),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// C. SECTION ROOTS — descending to the first meaningful widget
// ─────────────────────────────────────────────────────────────────────────────

class SectionRootCases extends StatelessWidget {
  const SectionRootCases({super.key});

  // C1 root is reached through a builder closure, two levels deep.
  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext ctx, Object constraints) {
        return BlocBuilder<Object, int>(
          builder: (BuildContext ctx2, int state) {
            // Expected: THIS Container is wrapped as the section root.
            return Container(
              color: 'black',
              child: Column(
                children: <Widget>[
                  _buildHeader(context),
                  _passThrough(context),
                  _buildList(context),
                  const NestedPanel(),
                ],
              ),
            );
          },
        );
      },
    );
  }

  // C2 root reached through a structural chain SizedBox > Padding > Container.
  Widget _buildHeader(BuildContext context) {
    return SizedBox(
      height: 48,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Container(
          // C3 SKIP — this inner Container is decorative, not a section root.
          child: Row(
            children: <Widget>[
              const Expanded(child: FusionAppText(text: 'Header')),
              Container(width: 13, height: 13, color: 'red'),
            ],
          ),
        ),
      ),
    );
  }

  // C4 SKIP — a pass-through to another build method; that method instruments
  // itself, so wrapping here too would put two nodes on one subtree.
  Widget _passThrough(BuildContext context) => _buildHeader(context);

  // C5 SKIP — expression-bodied body is read, but a scrollable is transparent
  // like any other structural widget, and its rows live behind `itemBuilder`
  // in a widget that instruments itself. Nothing is wrapped here.
  Widget _buildList(BuildContext context) => ListView.builder(
        shrinkWrap: true,
        itemCount: 3,
        itemBuilder: (BuildContext c, int i) => const RowItem(),
      );
}

// C6 multiple returns — each early return is its own section root.
class EarlyReturnCases extends StatelessWidget {
  const EarlyReturnCases({super.key, this.isEmpty = false});

  final bool isEmpty;

  @override
  Widget build(BuildContext context) {
    if (isEmpty) {
      return Container(
        child: const Center(child: FusionAppText(text: localizedEmpty)),
      );
    }
    return Container(
      child: const Center(child: FusionAppText(text: 'Has content')),
    );
  }
}

const String localizedEmpty = 'Nothing here yet';

// ─────────────────────────────────────────────────────────────────────────────
// D. SKIP CASES
// ─────────────────────────────────────────────────────────────────────────────

class SkipCases extends StatelessWidget {
  const SkipCases({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        // D1 SKIP — already the child of a SemanticHelper call.
        SemanticHelper.container(
          testId: SemanticHelper.createTestId(SemanticTypes.section, 'preexisting'),
          child: Container(color: 'blue'),
        ),

        // D2 SKIP — whole expression is const, a non-const wrapper cannot go in.
        const SizedBox(
          width: 239,
          child: Center(child: Text('Const subtree')),
        ),

        // D3 SKIP — value types are not widgets.
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xFF000000),
            borderRadius: BorderRadius.circular(16),
          ),
          child: const Text('Styled', style: TextStyle(fontSize: 12)),
        ),

        // D4 SKIP — NestedPanel is declared in this target, so it instruments
        // its own build method; wrapping the use site would double up.
        const NestedPanel(),

        // D5 SKIP — structural widgets are transparent.
        const Row(children: <Widget>[Expanded(child: Divider())]),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// E. PARSER ROBUSTNESS — these must not corrupt offsets
// ─────────────────────────────────────────────────────────────────────────────

class ParserTortureCases extends StatelessWidget {
  const ParserTortureCases({super.key, this.items = const <int>[]});

  final List<int> items;

  @override
  Widget build(BuildContext context) {
    return Container(
      child: Column(
        children: <Widget>[
          // E1 braces and parens inside a string literal
          const FusionAppText(text: 'Total (incl. tax) {net}'),

          // E2 escaped quote
          const FusionAppText(text: 'it\'s fine'),

          // E3 raw string with backslashes and parens
          const FusionAppText(text: r'C:\raw\(path)'),

          // E4 adjacent string literals
          const FusionAppText(text: 'Hello ' 'World'),

          // E5 interpolation containing a nested call
          FusionAppText(text: 'Count: ${items.length}'),

          // E6 a comment that looks like code: Container( child: Text('x') )
          /* another one: SemanticHelper.container(testId: 'nope') */
          const FusionAppText(text: 'After comments'),

          // E7 nested generics
          BlocBuilder<Object, List<List<int>>>(
            builder: (BuildContext c, List<List<int>> s) => const Text('Generic'),
          ),

          // E8 collection-if and spread
          if (items.isNotEmpty) const Text('Conditional child'),
          ...<Widget>[const Text('Spread child')],
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// F. NAMING COLLISIONS
// ─────────────────────────────────────────────────────────────────────────────

class CollisionCases extends StatelessWidget {
  const CollisionCases({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        // F1 two identical labels -> second becomes `duplicate_label_2`
        const FusionAppText(text: 'Duplicate label'),
        const FusionAppText(text: 'Duplicate label'),

        // F2 an id already used in the source is reserved, so a generated
        // `reserved_name` must not be handed out again.
        const FusionAppText(text: 'Reserved name', semanticId: 'reserved_name'),
        const FusionAppText(text: 'Reserved name'),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// G. `title:` HOLDING A WIDGET — the label type-safety guard
// ─────────────────────────────────────────────────────────────────────────────

class TitleWidgetCases extends StatelessWidget {
  const TitleWidgetCases({super.key});

  // Expected: named `zone_a` by reaching through the Text widget, but NO
  // `label:` argument emitted — a Widget cannot go into `String? label`.
  @override
  Widget build(BuildContext context) {
    return SectionTile(
      title: const Text('Zone A'),
      onTap: () {},
      child: const FusionAppText(text: 'Tile body'),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Project-declared widgets used above
// ─────────────────────────────────────────────────────────────────────────────

class NestedPanel extends StatelessWidget {
  const NestedPanel({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: 'grey',
      child: const FusionAppText(text: 'Nested panel'),
    );
  }
}

class RowItem extends StatelessWidget {
  const RowItem({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      child: const FusionAppText(text: 'Row item'),
    );
  }
}
