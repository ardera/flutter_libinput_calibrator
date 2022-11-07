import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:tuple/tuple.dart';
import 'common.dart';

class CalibrationOverlay extends StatefulWidget {
  const CalibrationOverlay({
    Key? key,
    required this.alignment,
    required this.onPressed,
  }) : super(key: key);

  final AlignmentGeometry alignment;
  final void Function(Offset touch, Offset buttonCenter) onPressed;

  @override
  State<CalibrationOverlay> createState() => _CalibrationOverlayState();
}

class _CalibrationOverlayState extends State<CalibrationOverlay> {
  final buttonKey = GlobalKey();

  Offset _getCenter() {
    final renderObject = buttonKey.currentContext!.findRenderObject();
    if (renderObject is! RenderBox) {
      throw StateError('Can\'t find global position of calibration button.');
    }

    return renderObject.localToGlobal(renderObject.size.center(Offset.zero));
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (details) {
        widget.onPressed(details.globalPosition, _getCenter());
      },
      child: Align(
        alignment: widget.alignment,
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: SizedBox(
            key: buttonKey,
            width: 75,
            height: 75,
            child: const Center(
              child: Icon(
                Icons.add_rounded,
                size: 75,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class PromptTouchScreen extends StatelessWidget {
  const PromptTouchScreen({
    Key? key,
    required this.alignment,
    required this.completer,
  }) : super(key: key);

  final AlignmentGeometry alignment;
  final Completer<Tuple2<Offset, Offset>> completer;

  @override
  Widget build(context) {
    return Stack(
      children: [
        const Positioned.fill(
          child: Align(
            alignment: Alignment.center,
            child: Text('Press the plus to continue.'),
          ),
        ),
        Positioned.fill(
          child: CalibrationOverlay(
            alignment: alignment,
            onPressed: (touch, target) {
              final size = MediaQuery.of(context).size;

              if (!completer.isCompleted) {
                completer.complete(
                  Tuple2(
                    // transform to a range 0..1
                    touch.scale(1 / size.width, 1 / size.height),
                    target.scale(1 / size.width, 1 / size.height),
                  ),
                );
              }
            },
          ),
        ),
      ],
    );
  }
}

class WaitForTsScreen extends StatelessWidget {
  const WaitForTsScreen({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        children: const [
          CircularProgressIndicator(),
          Text('Querying available touchscreens...')
        ],
      ),
    );
  }
}

class SelectTsScreen extends StatefulWidget {
  const SelectTsScreen({
    Key? key,
    required this.touchscreens,
    required this.completer,
  }) : super(key: key);

  final List<Touchscreen> touchscreens;
  final Completer<Tuple2<Touchscreen, bool>?> completer;

  @override
  State<SelectTsScreen> createState() => _SelectTsScreenState();
}

class _SelectTsScreenState extends State<SelectTsScreen> {
  Touchscreen? selected;
  bool combineCalibrations = true;

  @override
  Widget build(BuildContext context) {
    final bool canCombineCalibrations = selected?.calibrationMatrix != null;

    late Widget checkbox;
    if (canCombineCalibrations) {
      checkbox = CheckboxListTile(
        title: const Text('Combine with current calibration'),
        subtitle: const Text(
            'Combine the calculated calibration with the one that\'s configured right now. This should always be selected unless you have an explicit reason not to.'),
        value: combineCalibrations,
        tristate: false,
        onChanged: (value) {
          setState(() => combineCalibrations = value!);
        },
      );
    } else {
      checkbox = const CheckboxListTile(
        title: Text('Combine with current calibration (not applicable)'),
        subtitle: Text(
            'Combine the calculated calibration with the one that\'s configured right now. This should always be selected unless you have an explicit reason not to.'),
        value: false,
        onChanged: null,
      );
    }

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Your touchscreen is now calibrated for the duration of this flutter session.',
          ),
          const Text('Select the touchscreen to apply the calibration to:'),
          const Padding(padding: EdgeInsets.only(top: 8)),
          DropdownButton<Touchscreen>(
            value: selected,
            hint: const Text('Select touchscreen...'),
            items: [
              for (final ts in widget.touchscreens)
                DropdownMenuItem(value: ts, child: Text(ts.name))
            ],
            onChanged: (item) {
              setState(() {
                combineCalibrations = true;
                selected = item;
              });
            },
          ),
          checkbox,
          const Padding(padding: EdgeInsets.only(top: 16)),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              OutlinedButton(
                onPressed: () => widget.completer.maybeComplete(null),
                child: const Text('Cancel (exit)'),
              ),
              const Padding(padding: EdgeInsets.only(left: 16)),
              ElevatedButton(
                onPressed: () {
                  if (selected != null) {
                    widget.completer
                        .maybeComplete(Tuple2(selected!, combineCalibrations));
                  }
                },
                child: const Text('Continue'),
              )
            ],
          )
        ],
      ),
    );
  }
}

class ShowApplyUdevRuleScreen extends StatelessWidget {
  const ShowApplyUdevRuleScreen({
    Key? key,
    required this.alreadyCalibrated,
    required this.combinedCalibrations,
    required this.applyUdevRule,
    required this.completer,
  }) : super(key: key);

  final bool alreadyCalibrated;
  final bool combinedCalibrations;
  final String applyUdevRule;
  final Completer<void> completer;

  @override
  Widget build(BuildContext context) {
    late final Widget instructions;
    if (alreadyCalibrated) {
      late String combinedCalibrationsMsg;
      if (combinedCalibrations) {
        combinedCalibrationsMsg =
            'The new calibration has been combined with the old one, so you can safely replace it with the new calibration.';
      } else {
        combinedCalibrationsMsg =
            'You chose to not combine the new calibration with the old one, which means you can\'t use it as a replacement for the old calibration in most cases.';
      }

      instructions = Column(
        children: [
          Card(
            elevation: 2,
            color: combinedCalibrations
                ? const Color(0xFFF0F0F0)
                : const Color.fromRGBO(255, 245, 157, 1),
            shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.all(Radius.circular(8)),
            ),
            child: Padding(
              padding: const EdgeInsets.all(12.0),
              child: Column(
                children: [
                  Text(
                    'There\'s already a calibration matrix configured for this display. $combinedCalibrationsMsg',
                    style: const TextStyle(fontSize: 15),
                  ),
                ],
              ),
            ),
          ),
          const Padding(padding: EdgeInsets.only(top: 32)),
          const Text(
            'To apply the calibration, remove the old one and then do:',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          )
        ],
      );
    } else {
      instructions = const Text('To apply the calibration:',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600));
    }

    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            instructions,
            const Padding(padding: EdgeInsets.only(top: 8)),
            Container(
              decoration: BoxDecoration(color: Colors.grey.shade300),
              padding: const EdgeInsets.all(8),
              child: Text(
                applyUdevRule,
                style: GoogleFonts.robotoMono(
                  fontWeight: FontWeight.w600,
                  fontSize: 12,
                ),
              ),
            ),
            Text(
              '(this text was outputed to the terminal too, so you can copy & paste it from there)',
              style: TextStyle(
                color: Colors.grey.shade700,
              ),
            ),
            const Padding(padding: EdgeInsets.only(top: 32)),
            ElevatedButton(
              onPressed: () => completer.maybeComplete(),
              child: const Text('Finish (exit)'),
            )
          ],
        ),
      ),
    );
  }
}

class TouchFeedbackPainter extends CustomPainter {
  TouchFeedbackPainter(this.positions);

  final Set<Offset> positions;

  @override
  void paint(Canvas canvas, Size size) {
    final innerPaint = Paint()
      ..color = Colors.grey
      ..style = PaintingStyle.fill;

    final outerPaint = Paint()
      ..color = Colors.black
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5;

    for (final point in positions) {
      if (!size.contains(point)) {
        continue;
      }
      canvas.drawCircle(point, 16, innerPaint);
      canvas.drawCircle(point, 16, outerPaint);
    }
  }

  @override
  bool shouldRepaint(TouchFeedbackPainter oldDelegate) {
    return !(oldDelegate.positions.containsAll(positions) &&
        positions.containsAll(oldDelegate.positions));
  }
}

class TouchFeedbackOverlay extends StatefulWidget {
  const TouchFeedbackOverlay({Key? key, required this.child}) : super(key: key);

  final Widget child;

  @override
  State<TouchFeedbackOverlay> createState() => _TouchFeedbackOverlayState();
}

class _TouchFeedbackOverlayState extends State<TouchFeedbackOverlay> {
  final touchPositions = <int, Offset>{};

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (e) {
        if (e.kind == PointerDeviceKind.touch && mounted) {
          setState(() => touchPositions[e.pointer] = e.localPosition);
        }
      },
      onPointerMove: (e) {
        if (e.kind == PointerDeviceKind.touch && mounted) {
          setState(() => touchPositions[e.pointer] = e.localPosition);
        }
      },
      onPointerUp: (e) {
        if (e.kind == PointerDeviceKind.touch && mounted) {
          setState(() => touchPositions.remove(e.pointer));
        }
      },
      child: CustomPaint(
        foregroundPainter: TouchFeedbackPainter(
          touchPositions.values.toSet(),
        ),
        child: widget.child,
      ),
    );
  }
}

mixin MyWidgetsBinding on WidgetsBinding {}

/// A specific variant of [WidgetsFlutterBinding] that can apply a transform
/// to all the global positions of all pointer events.
/// When using RenderObjects, you can only transform the [PointerEvent.localPosition]
/// for any child widgets. Some RenderObjects rely on [PointerEvent.position] too though,
/// so that needs to be transformed too.
class MyWidgetsFlutterBinding extends BindingBase
    with
        GestureBinding,
        SchedulerBinding,
        ServicesBinding,
        PaintingBinding,
        SemanticsBinding,
        RendererBinding,
        WidgetsBinding {
  static WidgetsBinding ensureInitialized() {
    if (_instance == null) {
      return MyWidgetsFlutterBinding();
    }
    return instance;
  }

  /// The current [MyWidgetsFlutterBinding], if one has been created.
  ///
  /// Provides access to the features exposed by this binding. The binding must
  /// be initialized before using this getter; this is typically done by calling
  /// [testWidgets] or [MyWidgetsFlutterBinding.ensureInitialized].
  static MyWidgetsFlutterBinding get instance {
    return BindingBase.checkInstance(_instance);
  }

  static MyWidgetsFlutterBinding? _instance;

  Matrix4? pointerEventGlobalTransform;

  @override
  void handlePointerEvent(PointerEvent event) {
    if (pointerEventGlobalTransform != null) {
      super.handlePointerEvent(
        event.copyWith(
          position: MatrixUtils.transformPoint(
            pointerEventGlobalTransform!,
            event.position,
          ),
        ),
      );
    } else {
      super.handlePointerEvent(event);
    }
  }
}
