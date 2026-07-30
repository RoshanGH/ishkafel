import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/playback/playback_controller.dart';

void main() {
  group('FakePlaybackController 行为契约', () {
    late FakePlaybackController controller;

    setUp(() {
      controller = FakePlaybackController();
    });

    tearDown(() async {
      await controller.dispose();
    });

    test('open 后 positionMs==0 且 !isPlaying', () async {
      await controller.open('/tmp/fake.mp4');

      expect(controller.positionMs, 0);
      expect(controller.isPlaying, isFalse);
    });

    test('seekMs 更新位置并进流', () async {
      final emitted = <int>[];
      final sub = controller.positionMsStream.listen(emitted.add);

      await controller.seekMs(5000);
      await Future<void>.delayed(Duration.zero);

      expect(controller.positionMs, 5000);
      expect(emitted, contains(5000));

      await sub.cancel();
    });

    test('stepFrames(1, 30) 位置 +33ms（帧对齐 round）', () async {
      await controller.seekMs(1000);

      await controller.stepFrames(1, 30);

      expect(controller.positionMs, 1033);
    });

    test('stepFrames(-1) 不小于 0', () async {
      await controller.seekMs(10);

      await controller.stepFrames(-1, 30);

      expect(controller.positionMs, 0);
    });

    test('play/pause 切换 isPlaying', () async {
      await controller.play();
      expect(controller.isPlaying, isTrue);

      await controller.pause();
      expect(controller.isPlaying, isFalse);
    });

    test('调用记录（calls 列表）可断言', () async {
      await controller.open('/tmp/fake.mp4');
      await controller.play();
      await controller.pause();
      await controller.seekMs(100);
      await controller.stepFrames(1, 30);

      expect(controller.calls, [
        'open(/tmp/fake.mp4)',
        'play()',
        'pause()',
        'seekMs(100)',
        'stepFrames(1, 30.0)',
      ]);
    });
  });
}
