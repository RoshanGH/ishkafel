import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/cli/cli_output.dart';
import 'package:ishkafel/cli/commands/script_run_command.dart';
import 'package:ishkafel/core/miaoa/miaoa_tag_service.dart';
import 'package:ishkafel/core/storage/file_task_repository.dart';

class _FakeTagService implements MiaoaTagService {
  @override
  Future<List<TagGroup>> listGroups() async => const [
        TagGroup(
            id: 1261,
            name: '生活场景',
            materialType: 'video',
            tagType: 'public'),
      ];

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// `script new` 建出来的任务此前从不写 `unitTagGroups`/`shotTagGroups`——
/// 而 `script shots` / `tag-ref` 后面真的会读这两个字段（见
/// `script_command.dart:400,809-811`）。GUI 向导建脚本任务会把
/// `--tag-groups` 解析出的标签组写进去，CLI 这条路不写，就是
/// CLAUDE.md 点名的那条静默失败链：没有标签组 → AI 打不出标签 →
/// 挑素材时没有标签可检索——而这条链在真机上撞过。
///
/// 人在界面上能拧的旋钮（新建向导的标签组），Agent 用 CLI 建脚本任务
/// 时也必须能拧——`blank create` 已经是这个形状，这里补齐。
void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('ishkafel_scriptnew_'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('不给标签组直接拒绝——和 blank create 一样的判断', () async {
    final err = StringBuffer();
    final code = await runScriptNewCommand(
        rest: ['脚本任务'], dataDir: dir, err: err);
    expect(code, exitBadUsage);
    expect(err.toString(), contains('--tag-groups'));
  });

  test('给了标签组：真的落到任务的 unitTagGroups / shotTagGroups 上', () async {
    final out = StringBuffer();
    final code = await runScriptNewCommand(
      rest: ['脚本任务'],
      dataDir: dir,
      tagGroups: '1261',
      tagService: _FakeTagService(),
      out: out,
    );
    expect(code, 0);
    final id = (jsonDecode(out.toString()) as Map<String, dynamic>)['taskId'];
    final task = await FileTaskRepository(dir).findById('$id');
    expect(task!.unitTagGroups.map((g) => g.id), contains(1261));
    expect(task.shotTagGroups.map((g) => g.id), contains(1261));
  });

  test('给的标签组当前企业下找不到：拒绝并点名', () async {
    final err = StringBuffer();
    final code = await runScriptNewCommand(
      rest: ['脚本任务'],
      dataDir: dir,
      tagGroups: '9999',
      tagService: _FakeTagService(),
      err: err,
    );
    expect(code, exitNotFound);
    expect(err.toString(), contains('9999'));
  });
}
