import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/export/export_commands.dart';
import 'package:ishkafel/core/ffmpeg/proxy_spec.dart';

/// 预览用的变速切片要**带着素材自己的声音**，导出用的不带。
///
/// 两边不是一回事：
/// - **导出**把画面和声音拆成两条路走（画面 concat、声音单独合成再混流），
///   切片带声音只会在 concat 时多一条谁也不用的音轨；
/// - **预览**是 mpv 同时播几条轨，「替换分镜的声音」这一层读的就是这个切片
///   （见 [MultitrackPlayback.source]）。切片不带声音，这一层在预览里就是哑的
///   ——而导出会有。人照着预览挑完组合，拿到的成片多一层声音。
///
/// 声音必须跟画面**同速**：画面走 `setpts=PTS/倍率`，声音要走等效的
/// `atempo`，否则同一个文件里画面和声音各走各的。
String _vf(List<String> args) => args[args.indexOf('-vf') + 1];
String? _af(List<String> args) {
  final i = args.indexOf('-af');
  return i < 0 ? null : args[i + 1];
}

void main() {
  final proxy = ProxySpec.at('30/1');

  group('导出用的切片：不带声音', () {
    test('照旧 -an——导出的声音单独成轨', () {
      final args = ExportCommands.fitCandidateVideo(
        input: '/m.mp4',
        durationMs: 3000,
        candidateDurationMs: 4500,
        out: '/o.mp4',
      );

      expect(args, contains('-an'));
      expect(_af(args), isNull);
    });
  });

  group('预览用的切片：带声音，且和画面同速', () {
    test('不丢声音', () {
      final args = ExportCommands.fitCandidateVideo(
        input: '/m.mp4',
        durationMs: 3000,
        candidateDurationMs: 4500,
        out: '/o.mp4',
        target: proxy,
        keepAudio: true,
      );

      expect(args, isNot(contains('-an')),
          reason: '这一层在预览里读的就是这个文件，丢了声音就是哑的');
    });

    test('画面 1.5× 时声音也 1.5×', () {
      final args = ExportCommands.fitCandidateVideo(
        input: '/m.mp4',
        durationMs: 3000,
        candidateDurationMs: 4500,
        out: '/o.mp4',
        target: proxy,
        keepAudio: true,
      );

      expect(_vf(args), contains('setpts=PTS/1.5'));
      expect(_af(args), 'atempo=1.5');
    });

    test('倍率超过 2× 时拆成多节——atempo 单节只保证 0.5~2.0', () {
      final args = ExportCommands.fitCandidateVideo(
        input: '/m.mp4',
        durationMs: 1000,
        candidateDurationMs: 5000,
        out: '/o.mp4',
        target: proxy,
        keepAudio: true,
      );

      expect(_vf(args), contains('setpts=PTS/5'));
      expect(_af(args), 'atempo=2.0,atempo=2.0,atempo=1.25',
          reason: '2.0 × 2.0 × 1.25 = 5，和画面那个 5 是同一个数');
    });

    test('不变速时不插 atempo——白走一道只会掉音质', () {
      final args = ExportCommands.fitCandidateVideo(
        input: '/m.mp4',
        durationMs: 3000,
        candidateDurationMs: 3000,
        out: '/o.mp4',
        target: proxy,
        keepAudio: true,
      );

      expect(args, isNot(contains('-an')));
      expect(_af(args), isNull);
    });
  });
}
