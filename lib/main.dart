// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:io' as io;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:equations/equations.dart';
import 'package:path/path.dart' show basename;
import 'package:tuple/tuple.dart';
import 'package:google_fonts/google_fonts.dart';

import 'common.dart';
import 'widgets.dart';

void main() {
  GoogleFonts.config.allowRuntimeFetching = false;
  // we need to use a custom widgets binding to be able to transform the
  // global position of pointer events.
  MyWidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

Stream<Touchscreen> findTouchscreens() async* {
  Future<String?> queryUdev(String devicePath, String propertyName) async {
    final result = await io.Process.run('udevadm', ['info', devicePath]);
    if (result.exitCode != 0) {
      throw io.ProcessException(
        'udevadm',
        ['info', devicePath],
        "Could not query udev hw database. ${result.stderr}",
        result.exitCode,
      );
    }

    final out = result.stdout as String;
    final match = RegExp('$propertyName=([^\\n]*)\n').firstMatch(out);
    if (match == null) {
      return null;
    }

    return match.group(1);
  }

  Future<String?> queryUdevAttribute(String devicePath, String attrName) async {
    final result = await io.Process.run('udevadm', ['info', '-a', devicePath]);
    if (result.exitCode != 0) {
      throw io.ProcessException(
        'udevadm',
        ['info', devicePath],
        "Could not query udev hw database. ${result.stderr}",
        result.exitCode,
      );
    }

    final out = result.stdout as String;
    final match = RegExp('ATTRS{$attrName}=="([^"]*)"').firstMatch(out);
    if (match == null) {
      return null;
    }

    return match.group(1);
  }

  await for (final entity in io.Directory('/dev/input').list()) {
    final path = entity.path;

    if (!basename(path).startsWith('event')) {
      continue;
    }

    if (await queryUdev(path, 'ID_INPUT_TOUCHSCREEN') != '1') {
      continue;
    }

    final name = await queryUdevAttribute(path, 'name');
    if (name == null) continue;

    final bustype = await queryUdevAttribute(path, 'id/bustype');
    if (bustype == null) continue;

    final product = await queryUdevAttribute(path, 'id/product');
    if (product == null) continue;

    final vendor = await queryUdevAttribute(path, 'id/vendor');
    if (vendor == null) continue;

    RealMatrix? calibrationMatrix;
    final calibrationMatrixStr =
        await queryUdev(path, 'LIBINPUT_CALIBRATION_MATRIX');
    if (calibrationMatrixStr != null) {
      try {
        final coeffs = RegExp(r'[0-9]+\.?[0-9]*')
            .allMatches(calibrationMatrixStr)
            .map((e) => e.group(0)!)
            .map(double.parse);

        if (coeffs.length != 6) {
          print(
            'Could not parse libinput calibration matrix for device $name. Number of matrix entries is not 6.',
          );
        }

        calibrationMatrix = RealMatrix.fromData(
          rows: 3,
          columns: 3,
          data: [
            coeffs.take(3).toList(),
            coeffs.skip(3).take(3).toList(),
            [0, 0, 1],
          ],
        );
      } on FormatException catch (e) {
        print(
          'could not parse libinput calibration matrix for device $name. $e',
        );
      }
    }

    yield Touchscreen(name, bustype, product, vendor, calibrationMatrix);
  }
}

CalibrationResult calibrate(List<Tuple2<Offset, Offset>> touches) {
  /// This is how the libinput calibration matrix is applied:
  ///
  /// ```
  /// [ a b c ]   [ x ]   [ x']
  /// [ d e f ] * [ y ] = [ y']
  /// [ 0 0 1 ]   [ 1 ]   [ 1 ]
  /// ```
  ///
  /// where x, y are the raw touch coordinates in a range from 0..1 (== NDC,
  /// normalized device coordinates)
  /// and x', y' are the calibrated touch coordinates 0..1
  ///
  /// This means we have 2 equations:
  ///
  /// a*x + b*y + c*1 = x'
  /// d*x + e*y + f*1 = y'
  ///
  /// To solve for a, b, c, d, e, f we can create two linear equations systems
  /// with 3 equations each:
  ///
  /// ```
  /// Equation system one (for a, b, c):
  /// I)   x'_1 = a*x_1 + b*y_1 + c
  /// II)  x'_2 = a*x_2 + b*y_2 + c
  /// III) x'_3 = a*x_3 + b*y_3 + c
  ///
  /// Equation system two (for d, e, f):
  /// I)   y'_1 = d*x_1 + e*y_1 + f
  /// II)  y'_2 = d*x_2 + e*y_2 + f
  /// III) y'_3 = d*x_3 + e*y_3 + f
  /// ```
  ///
  /// Note that we have 3 equations instead of 2 or 4 because that's the case
  /// where we get exactly one solution. (Instead of none or infinitely many)
  /// (At least that's the case when all equations are linearly independent)
  ///
  /// So we actually only need three touch points instead of four. We could use
  /// the fourth or possibly more touchpoints to achieve a better solution, since
  /// of course the user doesn't always hit the button at _exactly_ the right place.
  ///
  /// To solve the equation system, we need to bring it into the form:
  /// `Ax = b`
  ///
  /// where A is a matrix, x is the vector we're solving for, and b is a vector.
  ///
  /// Substituting in our touch points, for us the equations for abc and def
  /// look like this:
  /// ```
  /// For a, b, c:
  /// [ x_1 y_1 1 ]   [ a ]   [ x'_1 ]
  /// [ x_2 y_2 1 ] * [ b ] = [ x'_2 ]
  /// [ x_3 y_3 1 ]   [ c ]   [ x'_3 ]
  ///
  /// For d, e, f:
  /// [ x_1 y_1 1 ]   [ d ]   [ y'_1 ]
  /// [ x_2 y_2 1 ] * [ e ] = [ y'_2 ]
  /// [ x_3 y_3 1 ]   [ f ]   [ y'_3 ]
  /// ```
  ///
  /// Now we can use gaussian elimination to solve for abc and def.

  final solverABC = GaussianElimination(
    matrix: RealMatrix.fromData(
      rows: 3,
      columns: 3,
      data: [
        for (final touch in touches.take(3))
          [touch.item1.dx, touch.item1.dy, 1],
      ],
    ),
    knownValues: [
      for (final touch in touches.take(3)) touch.item2.dx,
    ],
  );

  final abc = solverABC.solve();

  final solverDEF = GaussianElimination(
    matrix: RealMatrix.fromData(
      rows: 3,
      columns: 3,
      data: [
        for (final touch in touches.take(3))
          [touch.item1.dx, touch.item1.dy, 1],
      ],
    ),
    knownValues: [
      for (final touch in touches.take(3)) touch.item2.dy,
    ],
  );

  final def = solverDEF.solve();

  return CalibrationResult(
    RealMatrix.fromData(
      columns: 3,
      rows: 3,
      data: [
        abc,
        def,
        [0, 0, 1]
      ],
    ),
  );
}

class UnmountedException implements Exception {}

class Calibrator extends StatefulWidget {
  const Calibrator({Key? key}) : super(key: key);

  @override
  State<Calibrator> createState() => _CalibratorState();
}

class _CalibratorState extends State<Calibrator> {
  late Widget body;
  RealMatrix? touchTransform;
  void Function()? onDisposed;

  final materialAppKey = GlobalKey(debugLabel: 'material app');

  Never exit() {
    return io.exit(0);
  }

  Future<void> run() async {
    // let the user touch every corner of the screen
    final touches = [
      await promptTouch(Alignment.topLeft),
      await promptTouch(Alignment.topRight),
      await promptTouch(Alignment.bottomLeft),
      await promptTouch(Alignment.bottomRight),
    ];

    // get a calibration matrix
    final localResult = calibrate(touches);

    var a = localResult.a.toStringAsFixed(4);
    var b = localResult.b.toStringAsFixed(4);
    var c = localResult.c.toStringAsFixed(4);
    var d = localResult.d.toStringAsFixed(4);
    var e = localResult.e.toStringAsFixed(4);
    var f = localResult.f.toStringAsFixed(4);

    print("calculated calibration matrix:");
    print('[$a $b $c]');
    print('[$d $e $f]');
    print('[     0      0      1]');

    // We can ignore this because we always check if the widget has been disposed
    // before continuing. So the context should always be valid
    // ignore: use_build_context_synchronously
    final size = MediaQuery.of(context).size;

    final fromNDC = Matrix4.diagonal3Values(size.width, size.height, 1);
    final calibration = Matrix4.identity()
      ..setEntry(0, 0, localResult.matrix.itemAt(0, 0))
      ..setEntry(0, 1, localResult.matrix.itemAt(0, 1))
      ..setEntry(0, 3, localResult.matrix.itemAt(0, 2))
      ..setEntry(1, 0, localResult.matrix.itemAt(1, 0))
      ..setEntry(1, 1, localResult.matrix.itemAt(1, 1))
      ..setEntry(1, 3, localResult.matrix.itemAt(1, 2));
    final toNDC = Matrix4.diagonal3Values(1 / size.width, 1 / size.height, 1);

    (GestureBinding.instance as MyWidgetsFlutterBinding)
        .pointerEventGlobalTransform = fromNDC * calibration * toNDC;

    /// TODO: Ask the user here if he would like to increase the accuracy of the
    /// calibration, by doing more button presses.

    // query all connected touchscreens
    final touchscreens = await waitForTouchscreens();

    // let the user select the touchscreen that calibration should be
    // applied for
    final selected = await selectTouchscreen(touchscreens);
    if (selected == null) {
      // There's no touchscreen selected, so the user
      // must have canceled.
      print('Exiting...');
      exit();
    }

    final selectedTs = selected.item1;
    final combineCalibrations = selected.item2;

    // could be the touchscreen already has a calibration matrix associated
    // with it. In that case, we need to
    final alreadyCalibrated = selectedTs.calibrationMatrix != null;

    late CalibrationResult globalResult;
    if (alreadyCalibrated && combineCalibrations) {
      globalResult = CalibrationResult(
        (localResult.matrix * selectedTs.calibrationMatrix!) as RealMatrix,
      );
    } else {
      globalResult = localResult;
    }

    a = globalResult.a.toStringAsFixed(4);
    b = globalResult.b.toStringAsFixed(4);
    c = globalResult.c.toStringAsFixed(4);
    d = globalResult.d.toStringAsFixed(4);
    e = globalResult.e.toStringAsFixed(4);
    f = globalResult.f.toStringAsFixed(4);

    final applyUdevRule =
        'sudo bash -c \'echo \'\\\'\'ATTRS{name}=="${selectedTs.name}", ENV{LIBINPUT_CALIBRATION_MATRIX}="$a $b $c $d $e $f"\'\\\'\' > /etc/udev/rules.d/98-touchscreen-cal.rules\'';

    if (alreadyCalibrated) {
      print(
          'There\'s already a calibration matrix configured for this display.');
      if (combineCalibrations) {
        print(
            'The new calibration has been combined with the old one, so you can safely replace it with the new one.');
      } else {
        print(
            'You chose to not combine the new calibration with the old one, which means you can\'t use it as a replacement for the old calibration in most cases.');
      }
      print(
          'To apply the new calibration, remove the old one and then copy & paste this line into your terminal:');
      print(applyUdevRule);
    } else {
      print('To apply, copy & paste this line into your terminal:');
      print(applyUdevRule);
    }

    await showApplyUdevRule(
        alreadyCalibrated, combineCalibrations, applyUdevRule);

    // ideally we should flutters sane way of exiting instead.
    print('Exiting...');
    exit();
  }

  @override
  void initState() {
    super.initState();

    if (!io.Platform.isLinux) {
      throw StateError('Only linux is supported for calibration.');
    }

    // throw away all the UnmountedExceptions
    run().catchError(
      (err, stackTrace) {},
      test: (err) => err is UnmountedException,
    );
  }

  @override
  void dispose() {
    if (onDisposed != null) {
      onDisposed!();
    }
    super.dispose();
  }

  Future<Tuple2<Offset, Offset>> promptTouch(
    AlignmentGeometry alignment,
  ) async {
    final completer = Completer<Tuple2<Offset, Offset>>();
    final body = PromptTouchScreen(
      alignment: alignment,
      completer: completer,
    );

    setState(() {
      this.body = body;
      onDisposed = () {
        completer.maybeCompleteError(UnmountedException());
      };
    });

    return completer.future;
  }

  Future<List<Touchscreen>> waitForTouchscreens() async {
    final completer = Completer<List<Touchscreen>>();
    const body = WaitForTsScreen();

    findTouchscreens().toList().then(
          completer.complete,
          onError: completer.maybeCompleteError,
        );

    setState(() {
      this.body = body;
      onDisposed = () => completer.completeError(UnmountedException());
    });

    return completer.future;
  }

  Future<Tuple2<Touchscreen, bool>?> selectTouchscreen(
    List<Touchscreen> touchscreens,
  ) async {
    final completer = Completer<Tuple2<Touchscreen, bool>?>();

    final body = SelectTsScreen(
      touchscreens: touchscreens,
      completer: completer,
    );

    setState(() {
      this.body = body;
      onDisposed = () => completer.maybeCompleteError(UnmountedException());
    });

    return completer.future;
  }

  Future<void> showApplyUdevRule(
      bool alreadyCalibrated, bool combinedCalibrations, String rule) {
    final completer = Completer<void>();

    final body = ShowApplyUdevRuleScreen(
      alreadyCalibrated: alreadyCalibrated,
      combinedCalibrations: combinedCalibrations,
      applyUdevRule: rule,
      completer: completer,
    );

    setState(() {
      this.body = body;
      onDisposed = () => completer.maybeCompleteError(UnmountedException());
    });

    return completer.future;
  }

  @override
  Widget build(BuildContext context) {
    Widget widget = Scaffold(
      appBar: null,
      body: body,
    );

    return widget;
  }
}

class MyApp extends StatelessWidget {
  const MyApp({Key? key}) : super(key: key);

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    return TouchFeedbackOverlay(
      child: MaterialApp(
        title: 'Flutter Libinput Calibrator',
        theme: ThemeData(
          primarySwatch: Colors.blue,
        ),
        home: const Calibrator(),
      ),
    );
  }
}
