import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/miaoa/miaoa_project_service.dart';
import 'package:ishkafel/core/miaoa/miaoa_tag_service.dart' show MiaoaException;

/// 取自真实 `miaoa project list --json` 的返回结构
String _realShaped() => jsonEncode({
      'records': [
        {'id': 181, 'name': '大贸便携DDS三组', 'isEnabled': true},
        {'id': 104, 'name': '滴露植源喷雾', 'isEnabled': true},
      ],
      'total': 2,
      'current': 1,
      'size': 200,
    });

MiaoaProjectService _service(
  List<List<String>> calls, {
  String? stdout,
  String stderr = '',
  int exitCode = 0,
}) =>
    MiaoaProjectService(run: (bin, args) async {
      calls.add(args);
      return ProcessResult(1, exitCode, stdout ?? _realShaped(), stderr);
    });

void main() {
  test('拉全部启用中的项目，一页取完', () async {
    final calls = <List<String>>[];

    final projects = await _service(calls).listProjects();

    expect(projects.map((p) => p.id), [181, 104]);
    expect(projects.first.name, '大贸便携DDS三组');
    expect(calls.single, containsAllInOrder(['project', 'list']));
    expect(calls.single, contains('--enabled-only'),
        reason: '停用的项目不会再有新素材，摆在列表里只让人多翻几屏');
    expect(calls.single, containsAllInOrder(['--page-size', '200']),
        reason: '几十个项目一页装得下，翻页反而更慢');
  });

  test('个别条目畸形只跳过它，不牵连整份列表', () async {
    final projects = await _service(
      [],
      stdout: jsonEncode({
        'records': [
          {'id': 104, 'name': '滴露植源喷雾'},
          {'id': 'bad', 'name': '坏的'},
          {'name': '没有 id'},
          'not a map',
        ],
        'total': 4,
      }),
    ).listProjects();

    expect(projects.map((p) => p.id), [104]);
  });

  test('登录失效时给能据以行动的中文', () async {
    expect(
      () => _service([], exitCode: 1, stderr: '401 Unauthorized').listProjects(),
      throwsA(isA<MiaoaException>()
          .having((e) => e.message, 'message', contains('miaoa auth login'))),
    );
  });

  test('返回不是 JSON 时报格式错误，而不是抛一个看不懂的解析异常', () async {
    expect(
      () => _service([], stdout: '<html>502</html>').listProjects(),
      throwsA(isA<MiaoaException>()),
    );
  });
}
