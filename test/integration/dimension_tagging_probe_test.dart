// 探针：用真实素材 + 真实标签组跑一遍分维度打标，看标签是否各归其位。
//
//   flutter test test/integration/dimension_tagging_probe_test.dart \
//     --tags integration --run-skipped
@Tags(['integration'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/ai/ai_credentials.dart';
import 'package:ishkafel/core/ai/ark_chat_client.dart';
import 'package:ishkafel/core/ai/taggers.dart';
import 'package:ishkafel/core/analysis/tag_vocabulary.dart';
import 'package:ishkafel/core/analysis/tagging_service.dart';
import 'package:ishkafel/core/ffmpeg/thumbnail_service.dart';
import 'package:ishkafel/core/miaoa/miaoa_locator.dart';
import 'package:ishkafel/core/miaoa/miaoa_tag_service.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/models/tag_group_ref.dart';
import 'package:ishkafel/core/storage/file_task_repository.dart';

/// 用户定下的固定测试配置
const _shotGroups = ['植源场景', '植源镜头类别', '植源动作', '植源外壳'];

/// 给「植源场景」维度一段真实约束，验证它确实进了提示词并起了作用。
///
/// 首次探针用的是「只判断主体所处的空间（厨房/客厅/卫生间）」——结果那个
/// 维度**整个空了**，因为这个组的词表其实是物体/位置粒度的（橱柜、灶台置物
/// 台面、冰箱玻璃板、微波炉内壁），空间粒度的词在「植源外壳」组里（厨房情景
/// / 客厅情景）。这反过来证明约束确实被照做了：约束一旦和词表口径不符，
/// 模型宁可一个都不选。约束要按该组词表的粒度来写。
const _scenePrompt = '只判断画面里出现的具体位置/物体表面（如台面、柜门、'
    '冰箱层板），不要判断整体空间，也不要判断人物动作。';

const _videoPath =
    '/Users/menggang/Documents/滴露视频/JC_滴露_植源喷雾_XCT_SQ1&YY6_CH_千川直播_M66028501_0427.mp4';

/// 直接读用户数据目录里那条已切分好的任务，省去重跑分析
Future<RenewTask?> _storedTask() async {
  final dir = Directory('${Platform.environment['HOME']}/Library/'
      'Application Support/com.jichuang.ishkafel/ishkafel_data');
  if (!dir.existsSync()) return null;
  final repo = FileTaskRepository(dir);
  final all = await repo.findAll();
  return all.where((t) => t.sourcePath == _videoPath).firstOrNull;
}

void main() {
  final creds = CredentialsLoader.load(secretsDirs: [Directory('.secrets')]);
  final skip = creds.isComplete ? null : 'AI 凭据不完整';

  test('分维度打标：三帧 + 每维度独立词表与约束', () async {
    final task = await _storedTask();
    if (task == null) {
      // ignore: avoid_print
      print('本机没有那条任务，跳过');
      return;
    }

    final tagService = MiaoaTagService(binary: resolveMiaoaBinary());
    final groups = await tagService.listGroups();
    final shotRefs = [
      for (final name in _shotGroups)
        if (groups.where((g) => g.name == name).firstOrNull case final g?)
          TagGroupRef(
            id: g.id,
            name: g.name,
            prompt: g.name == '植源场景' ? _scenePrompt : null,
          ),
    ];
    expect(shotRefs, hasLength(_shotGroups.length),
        reason: '这四个组必须都能找到，否则测的就不是用户那套配置');

    final workDir = Directory.systemTemp.createTempSync('ishkafel_dim_');
    addTearDown(() => workDir.deleteSync(recursive: true));

    final service = TaggingService(
      shotTagger: ShotTagger(chat: ArkChatClient(apiKey: creds.arkApiKey)),
      thumbnails: ThumbnailService(),
      vocabulary: MiaoaTagVocabularySource(tagService),
      workDir: workDir,
    );

    // 只打头两个单元，够看清各维度是否各归其位，又不必等全片
    final probed = task.copyWith(shotTagGroups: shotRefs);
    final out = await service.tag(probed, task.units!, only: {0, 1});

    var withDimensions = 0;
    for (final u in out.take(2)) {
      for (var i = 0; i < u.shots.length; i++) {
        final s = u.shots[i];
        final byDim = s.trace?.tagsByDimension ?? const {};
        if (byDim.isNotEmpty) withDimensions++;
        // ignore: avoid_print
        print('U${u.index + 1}S${i + 1} 采样 ${s.trace?.sampledAtMs} '
            '${byDim.entries.map((e) => '${e.key}=${e.value.join("/")}').join('  ')}');
        // ignore: avoid_print
        print('        描述：${s.description ?? "（无）"}');
      }
    }

    expect(withDimensions, greaterThan(0), reason: '一个维度结果都没拿到');
    for (final u in out.take(2)) {
      for (final s in u.shots) {
        expect(s.trace?.sampledAtMs.length, lessThanOrEqualTo(3),
            reason: '固定三帧，不该再出现更多');
      }
    }
  }, timeout: const Timeout(Duration(minutes: 10)), skip: skip);
}
