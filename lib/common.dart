import 'dart:async';
import 'dart:math';

import 'package:equations/equations.dart';

class CalibrationResult {
  CalibrationResult(this.matrix);

  final RealMatrix matrix;

  late final a = matrix.itemAt(0, 0);
  late final b = matrix.itemAt(0, 1);
  late final c = matrix.itemAt(0, 2);
  late final d = matrix.itemAt(1, 0);
  late final e = matrix.itemAt(1, 1);
  late final f = matrix.itemAt(1, 2);

  CalibrationResult rounded(int digitsAfterDecimal) {
    final factor = pow(10, digitsAfterDecimal);
    return CalibrationResult(
      RealMatrix.fromFlattenedData(
        rows: 3,
        columns: 3,
        data: matrix
            .toList()
            .map((e) => (e * factor).roundToDouble() / factor)
            .toList(),
      ),
    );
  }
}

extension MaybeComplete<T> on Completer<T> {
  void maybeComplete([FutureOr<T>? result]) {
    if (!isCompleted) {
      complete(result);
    }
  }

  void maybeCompleteError(Object error, [StackTrace? stackTrace]) {
    if (!isCompleted) {
      completeError(error, stackTrace);
    }
  }
}

class Touchscreen {
  const Touchscreen(
    this.name,
    this.bustype,
    this.product,
    this.vendor,
    this.calibrationMatrix,
  );

  final String name;
  final String bustype;
  final String product;
  final String vendor;
  final RealMatrix? calibrationMatrix;
}
