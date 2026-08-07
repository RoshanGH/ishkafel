import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/features/workbench/replaced_duration_label.dart';

void main() {
  group('被整体替换的单元要标出成片里的新时长', () {
    test('变长了就写出来', () {
      expect(replacedDurationLabel(sourceMs: 4000, composedMs: 5200),
          '4.0s → 5.2s');
    });

    test('变短了也一样', () {
      expect(replacedDurationLabel(sourceMs: 6000, composedMs: 3000),
          '6.0s → 3.0s');
    });

    test('几乎没变就不标——差 30 毫秒写出来只是噪音', () {
      expect(replacedDurationLabel(sourceMs: 4000, composedMs: 4030), isNull);
    });

    test('没被替换（没有新时长）时不标', () {
      expect(replacedDurationLabel(sourceMs: 4000, composedMs: null), isNull);
    });

    test('新时长不合法时不标，不写出一个 0.0s', () {
      expect(replacedDurationLabel(sourceMs: 4000, composedMs: 0), isNull);
      expect(replacedDurationLabel(sourceMs: 4000, composedMs: -5), isNull);
    });
  });
}
