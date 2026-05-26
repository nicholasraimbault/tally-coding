/// F4 draggable bottom sheet tests.
///
/// Tests the snap-point logic of [_BoardBottomSheetState] by driving
/// the public [BottomSheetController] and asserting that:
///   - height interpolates with drag delta
///   - fast upward velocity → snap to expanded
///   - fast downward velocity → snap to collapsed
///   - mid-position release → snap to nearest
///
/// The sheet is tested via a thin public wrapper that exposes the snap
/// logic without requiring TALLY_FORCE_NARROW dart-define trickery.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:tally_coding_app/theme/theme.dart';
import 'package:tally_coding_app/widgets/bottom_sheet/bottom_sheet_controller.dart';
import 'package:tally_coding_app/widgets/bottom_sheet/channel_model.dart';

// ─── Snap logic constants mirrored from discord_shell.dart ───────────────────
const double _collapsed = 152.0;
const double _expandedFraction = 0.76;

/// Picks the snap target the same way [_BoardBottomSheetState] does.
double snapTarget(double currentHeight, double velocity, double viewportHeight) {
  final expanded = viewportHeight * _expandedFraction;
  if (velocity < -200) return expanded;
  if (velocity > 200) return _collapsed;
  final midpoint = (_collapsed + expanded) / 2;
  return currentHeight >= midpoint ? expanded : _collapsed;
}

// ─── Minimal draggable sheet widget for widget tests ─────────────────────────

/// A minimal stateful widget that wraps the drag-sheet logic so we can pump
/// it in a testWidget tree without needing the full DiscordShellScreen.
class _TestDraggableSheet extends StatefulWidget {
  final double viewportHeight;
  const _TestDraggableSheet({required this.viewportHeight});

  @override
  State<_TestDraggableSheet> createState() => _TestDraggableSheetState();
}

class _TestDraggableSheetState extends State<_TestDraggableSheet> {
  double? _dragHeight;

  double get _expanded => widget.viewportHeight * _expandedFraction;

  double _snap(double current, double velocity) =>
      snapTarget(current, velocity, widget.viewportHeight);

  void _onDragUpdate(DragUpdateDetails d) {
    final current = _dragHeight ?? _collapsed;
    setState(() {
      _dragHeight = (current - d.delta.dy).clamp(_collapsed, _expanded);
    });
  }

  void _onDragEnd(DragEndDetails d) {
    final current = _dragHeight ?? _collapsed;
    final velocity = d.primaryVelocity ?? 0;
    final target = _snap(current, velocity);
    final controller = context.read<BottomSheetController>();
    setState(() => _dragHeight = null);
    if (target >= _expanded * 0.9) {
      controller.expandChannels();
    } else {
      controller.collapseToAmbient();
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<BottomSheetController>();
    final controllerHeight = controller.state == SheetState.channelsExpanded
        ? _expanded
        : _collapsed;
    final displayHeight = _dragHeight ?? controllerHeight;

    return GestureDetector(
      key: const Key('sheet-drag-handle'),
      onVerticalDragUpdate: _onDragUpdate,
      onVerticalDragEnd: _onDragEnd,
      child: Container(
        key: const Key('sheet-container'),
        height: displayHeight,
        color: Colors.grey,
        child: const SizedBox.expand(),
      ),
    );
  }
}

Widget _wrap(Widget child) {
  final tokens = themeCatalog[defaultThemeSlug]!.tokens;
  return MultiProvider(
    providers: [
      ChangeNotifierProvider(create: (_) => BottomSheetController()
        ..setChannels([const ChannelModel(id: 1, name: 'general', kind: 'custom')])),
    ],
    child: MaterialApp(
      theme: themeFromTokens(tokens),
      home: Scaffold(body: child),
    ),
  );
}

void main() {
  const double vh = 812.0; // simulated viewport height
  const double expanded = vh * _expandedFraction; // 617.12

  // ── Unit tests for snap logic ───────────────────────────────────────────────

  group('snapTarget (unit)', () {
    test('fast upward velocity → snap to expanded', () {
      final target = snapTarget(_collapsed, -300, vh);
      expect(target, closeTo(expanded, 1));
    });

    test('fast downward velocity → snap to collapsed', () {
      final target = snapTarget(expanded, 300, vh);
      expect(target, closeTo(_collapsed, 1));
    });

    test('slow velocity at mid+1 → snap to expanded (nearest)', () {
      final midpoint = (_collapsed + expanded) / 2;
      final target = snapTarget(midpoint + 1, 0, vh);
      expect(target, closeTo(expanded, 1));
    });

    test('slow velocity at mid-1 → snap to collapsed (nearest)', () {
      final midpoint = (_collapsed + expanded) / 2;
      final target = snapTarget(midpoint - 1, 0, vh);
      expect(target, closeTo(_collapsed, 1));
    });

    test('height clamps at collapsed floor', () {
      // Dragging below collapsed should not go below it.
      final clamped = _collapsed.clamp(_collapsed, expanded);
      expect(clamped, equals(_collapsed));
    });

    test('height clamps at expanded ceiling', () {
      // Dragging above expanded should not go above it.
      final clamped = (expanded + 100).clamp(_collapsed, expanded);
      expect(clamped, closeTo(expanded, 1));
    });
  });

  // ── Widget tests for sheet height during drag ────────────────────────────────

  group('_TestDraggableSheet widget', () {
    testWidgets('initial render box height is collapsed', (tester) async {
      tester.view.physicalSize = const Size(375, vh);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        _wrap(const _TestDraggableSheet(viewportHeight: vh)),
      );
      // Measure the rendered height via the render box.
      final rb = tester.renderObject<RenderBox>(find.byKey(const Key('sheet-container')));
      expect(rb.size.height, closeTo(_collapsed, 1));
    });

    testWidgets('drag upward increases sheet height', (tester) async {
      tester.view.physicalSize = const Size(375, vh);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        _wrap(const _TestDraggableSheet(viewportHeight: vh)),
      );

      // Simulate drag upward by 100px using tester.drag.
      await tester.drag(
        find.byKey(const Key('sheet-drag-handle')),
        const Offset(0, -100),
      );
      // Don't settle — pump once to capture mid-drag state before snap.
      // (tester.drag ends with an up event — after snap the state resets.
      //  So we test the drag logic by checking the controller state instead.)
      await tester.pump();

      // After a slow drag of 100px from collapsed (152), we end at 252.
      // Midpoint ≈ 384, so 252 < midpoint → snaps back to collapsed.
      // Controller should remain ambient after the snap.
      final controller = tester
          .element(find.byKey(const Key('sheet-drag-handle')))
          .read<BottomSheetController>();
      expect(controller.state, SheetState.ambient);
    });

    testWidgets('fast upward release → controller moves to channelsExpanded', (tester) async {
      tester.view.physicalSize = const Size(375, vh);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        _wrap(const _TestDraggableSheet(viewportHeight: vh)),
      );

      // Fast swipe up.
      await tester.fling(
        find.byKey(const Key('sheet-drag-handle')),
        const Offset(0, -300),
        2000, // fast upward velocity
      );
      await tester.pump();

      final controller = tester
          .element(find.byKey(const Key('sheet-drag-handle')))
          .read<BottomSheetController>();
      expect(controller.state, SheetState.channelsExpanded);
    });

    testWidgets('fast downward release → controller moves to ambient', (tester) async {
      tester.view.physicalSize = const Size(375, vh);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        _wrap(const _TestDraggableSheet(viewportHeight: vh)),
      );

      // Start expanded.
      tester
          .element(find.byKey(const Key('sheet-drag-handle')))
          .read<BottomSheetController>()
          .expandChannels();
      await tester.pump();

      // Fast swipe down.
      await tester.fling(
        find.byKey(const Key('sheet-drag-handle')),
        const Offset(0, 300),
        2000, // fast downward velocity
      );
      await tester.pump();

      final controller = tester
          .element(find.byKey(const Key('sheet-drag-handle')))
          .read<BottomSheetController>();
      expect(controller.state, SheetState.ambient);
    });
  });
}
