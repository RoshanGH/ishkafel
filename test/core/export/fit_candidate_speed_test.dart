import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/export/export_commands.dart';

String _vf(List<String> args) => args[args.indexOf('-vf') + 1];

void main() {
  group('镜头替换：候选变速填满坑位', () {
    test('候选比坑位长时加速', () {
      final args = ExportCommands.fitCandidateVideo(
        input: '/m.mp4',
        durationMs: 3000,
        candidateDurationMs: 4500,
        out: '/o.mp4',
      );

      expect(_vf(args), contains('setpts=PTS/1.5'));
    });

    test('候选比坑位短时放慢', () {
      final args = ExportCommands.fitCandidateVideo(
        input: '/m.mp4',
        durationMs: 3000,
        candidateDurationMs: 2400,
        out: '/o.mp4',
      );

      expect(_vf(args), contains('setpts=PTS/0.8'));
    });

    test('一样长时不插变速滤镜——白走一道只会掉画质', () {
      final args = ExportCommands.fitCandidateVideo(
        input: '/m.mp4',
        durationMs: 3000,
        candidateDurationMs: 3000,
        out: '/o.mp4',
      );

      expect(_vf(args), isNot(contains('setpts')));
    });

    test('不知道候选多长时退回原来的裁/冻帧——不瞎猜倍率', () {
      final args = ExportCommands.fitCandidateVideo(
        input: '/m.mp4',
        durationMs: 3000,
        out: '/o.mp4',
      );

      expect(_vf(args), isNot(contains('setpts')));
      expect(_vf(args), contains('tpad'));
    });

    test('变速之后仍然锁死帧数——变速有舍入，差一帧后面全错位', () {
      final args = ExportCommands.fitCandidateVideo(
        input: '/m.mp4',
        durationMs: 3000,
        candidateDurationMs: 4500,
        out: '/o.mp4',
      );

      expect(args, containsAllInOrder(['-frames:v', '90']),
          reason: '3 秒 × 30fps');
    });

    test('变速时也补一道 tpad——舍入后可能差最后一两帧', () {
      final args = ExportCommands.fitCandidateVideo(
        input: '/m.mp4',
        durationMs: 3000,
        candidateDurationMs: 4500,
        out: '/o.mp4',
      );

      expect(_vf(args), contains('tpad'));
    });

    test('画面不带声音——镜头替换只换画面，口播用原片的', () {
      final args = ExportCommands.fitCandidateVideo(
        input: '/m.mp4',
        durationMs: 3000,
        candidateDurationMs: 4500,
        out: '/o.mp4',
      );

      expect(args, contains('-an'));
    });

    test('setpts 排在缩放之后、帧率归一之前', () {
      final vf = _vf(ExportCommands.fitCandidateVideo(
        input: '/m.mp4',
        durationMs: 3000,
        candidateDurationMs: 4500,
        out: '/o.mp4',
      ));

      expect(vf.indexOf('scale'), lessThan(vf.indexOf('setpts')),
          reason: '先缩放再变速，滤镜链顺序错了出来的分辨率就不对');
    });
  });
}
