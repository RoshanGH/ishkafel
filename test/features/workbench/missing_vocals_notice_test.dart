import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/audio/bgm_plan.dart';
import 'package:ishkafel/core/audio/voice_plan.dart';
import 'package:ishkafel/features/workbench/preview_tracks.dart';

/// 这条提示以前**只看人声轨文件在不在**，却一律归因到「工具没装」，还劝人
/// 「重新分析」——真机上（2026-09-04）用户早把工具装齐了，照做一百遍也好不了：
/// 命中分析缓存就直接返回，压根走不到分离那一步。
///
/// 提示必须说真话，并给一个**真的能解决问题**的出口。
void main() {
  const bgm = BgmPlan([
    BgmSegment(startUnit: 1, endUnit: 1, fit: BgmFit.cut, materials: [
      BgmMaterial(id: 7, name: '轻快', durationMs: 30000, previewUrl: null),
    ]),
  ]);
  const noVoices = VoicePlan([]);

  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('mvn'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('人声轨在，什么都不说', () {
    final vocals = File('${dir.path}/人声.wav')..writeAsStringSync('v');

    expect(missingVocalsNotice(bgm, noVoices, vocals.path), isNull);
  });

  test('没铺配乐就没这回事', () {
    expect(missingVocalsNotice(const BgmPlan([]), noVoices, null), isNull);
  });

  test('机器上没装工具：让人去装，不提「重新分析」——那治不好', () {
    final notice =
        missingVocalsNotice(bgm, noVoices, null, canSeparate: false);

    expect(notice, isNotNull);
    expect(notice!.text, contains('设置'), reason: '要指路，不能只说坏了');
    expect(notice.text, isNot(contains('重新分析')),
        reason: '重新分析救不了这个，说了就是骗人去做无用功');
    expect(notice.retryable, isFalse, reason: '工具都没有，重试也是白试');
  });

  test('工具装好了、人声轨却丢了：给「重新分离」的出口，别再劝人去装工具', () {
    final notice = missingVocalsNotice(
        bgm, noVoices, '${dir.path}/早就被删掉了.wav',
        canSeparate: true);

    expect(notice, isNotNull);
    expect(notice!.retryable, isTrue, reason: '这才是真能解决问题的出口');
    expect(notice.text, isNot(contains('装')),
        reason: '人家已经装好了，再劝一遍只会让他以为是自己没装对');
    expect(notice.text, isNot(contains('重新分析')),
        reason: '命中缓存时重新分析走不到分离那一步，等于让他白忙');
  });

  test('从来没分离过（路径为空）也走同一条出口', () {
    final notice = missingVocalsNotice(bgm, noVoices, null, canSeparate: true);

    expect(notice, isNotNull);
    expect(notice!.retryable, isTrue);
  });

  group('空白任务', () {
    test('声音全来自素材、逐条分离，装好工具就没这回事', () {
      expect(missingVocalsNotice(bgm, noVoices, null, isBlank: true), isNull);
    });

    test('没装工具时照样要说清，但那是素材的声音', () {
      final notice = missingVocalsNotice(bgm, noVoices, null,
          isBlank: true, canSeparate: false);

      expect(notice, isNotNull);
      expect(notice!.text, contains('设置'));
      expect(notice.retryable, isFalse);
    });
  });
}
