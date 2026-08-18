import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/cli/cli_output.dart';
import 'package:ishkafel/cli/commands/candidates_command.dart';
import 'package:ishkafel/core/miaoa/miaoa_content_service.dart';
import 'package:ishkafel/core/miaoa/miaoa_gateway.dart';
import 'package:ishkafel/core/miaoa/miaoa_tag_service.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/core/storage/file_task_repository.dart';

/// `ishkafel candidates` 的检索能力必须和 GUI 同源：Agent 曾经只有
/// 「标签 or 检索」一条路——没打上标签就无路可走，而 GUI 有画面描述
/// 降级、标签收窄、分页三道加工。
void main() {
  late Directory dir;

  RenewTask task({List<String> shotTags = const ['灶台']}) => RenewTask(
        id: 'c1',
        name: '检索',
        sourcePath: '/v/a.mp4',
        status: RenewTaskStatus.ready,
        createdAt: DateTime.utc(2026, 8, 18),
        updatedAt: DateTime.utc(2026, 8, 18),
        units: [
          SemanticUnit(index: 0, startMs: 0, endMs: 3000, transcript: 'A', shots: [
            Shot(startMs: 0, endMs: 3000, tags: shotTags),
          ]),
        ],
      );

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('ishkafel_cand_');
    await FileTaskRepository(dir).save(task());
  });
  tearDown(() => dir.deleteSync(recursive: true));

  /// 记录 miaoa CLI 收到的参数，按命令返回可控结果
  (MiaoaContentService, List<List<String>>) contentService(
      {int total = 3}) {
    final calls = <List<String>>[];
    final service = MiaoaContentService(
        gateway: MiaoaGateway(
      binary: 'miaoa',
      run: (_, args) async {
        calls.add(args);
        return ProcessResult(
            1,
            0,
            jsonEncode({
              'records': [
                {'id': 7, 'name': '素材七', 'sceneDescription': '喷洒'},
              ],
              'total': total,
            }),
            '');
      },
    ));
    return (service, calls);
  }

  test('--keyword 走画面描述语义搜——标签打不上时的第二条路', () async {
    final (service, calls) = contentService();
    final out = StringBuffer();
    final code = await runCandidatesCommand(
      rest: ['c1'],
      dataDir: dir,
      unitIndex: 0,
      shotIndex: 0,
      keyword: '厨房喷洒',
      contentService: service,
      out: out,
      err: StringBuffer(),
    );
    expect(code, 0);
    final args = calls.single;
    expect(args, containsAllInOrder(['--keyword', '厨房喷洒', '--by', 'content']));
    final json = jsonDecode(out.toString());
    expect(json['candidates'], hasLength(1));
    expect(json['page'], 1);
  });

  test('--page 翻页参数透传到检索', () async {
    final (service, calls) = contentService();
    final code = await runCandidatesCommand(
      rest: ['c1'],
      dataDir: dir,
      unitIndex: 0,
      shotIndex: 0,
      keyword: 'x',
      page: 3,
      contentService: service,
      out: StringBuffer(),
      err: StringBuffer(),
    );
    expect(code, 0);
    expect(calls.single, containsAllInOrder(['--page', '3']));
  });

  test('没有标签也没给 --keyword：指路到 --keyword，而不是死路', () async {
    await FileTaskRepository(dir).save(task(shotTags: const []));
    final err = StringBuffer();
    final code = await runCandidatesCommand(
      rest: ['c1'],
      dataDir: dir,
      unitIndex: 0,
      shotIndex: 0,
      contentService: contentService().$1,
      // 标签路径要拉词表，用不上但要给个不炸的
      tagService: MiaoaTagService(
          gateway: MiaoaGateway(
              binary: 'miaoa',
              run: (_, _) async => ProcessResult(1, 0, '[]', ''))),
      out: StringBuffer(),
      err: err,
    );
    expect(code, exitNotFound);
    expect(err.toString(), contains('--keyword'),
        reason: 'GUI 在这个位置会自动降级到画面描述，CLI 至少要指路');
  });

  test('--tag-mode 只认 and/or', () async {
    final err = StringBuffer();
    final code = await runCandidatesCommand(
      rest: ['c1'],
      dataDir: dir,
      unitIndex: 0,
      shotIndex: null,
      tagMode: '乱写',
      out: StringBuffer(),
      err: err,
    );
    expect(code, exitBadUsage);
  });
}
