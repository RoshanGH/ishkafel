import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/cli/cli_output.dart';
import 'package:ishkafel/cli/commands/subtitle_command.dart';

import '../support/seed_task.dart';

void main() {
  late Directory dataDir;
  setUp(() => dataDir = Directory.systemTemp.createTempSync('ishkafel_subcmd'));
  tearDown(() => dataDir.deleteSync(recursive: true));

  test('check 只出问题清单，别的什么都不给', () async {
    final id = (await seedTask(dataDir)).id;
    final out = StringBuffer();
    final code =
        await runSubtitleCommand(rest: ['check', id], dataDir: dataDir, out: out);
    expect(code, 0);
    final json = jsonDecode(out.toString()) as Map<String, dynamic>;
    expect(json.keys, contains('problems'));
    expect(json.containsKey('shots'), isFalse,
        reason: 'check 是入口，不是报告——给细节就没人看了');
  });

  test('show 出全片报告', () async {
    final id = (await seedTask(dataDir)).id;
    final out = StringBuffer();
    await runSubtitleCommand(rest: ['show', id], dataDir: dataDir, out: out);
    expect((jsonDecode(out.toString()) as Map).keys, contains('shots'));
  });

  test('不给子命令时还是老样子——样式现状', () async {
    final id = (await seedTask(dataDir)).id;
    final out = StringBuffer();
    final code =
        await runSubtitleCommand(rest: [id], dataDir: dataDir, out: out);
    expect(code, 0);
    expect(out.toString(), contains('preset'),
        reason: '老用法不许一声不响地失效');
  });

  test('任务不存在就直说', () async {
    final err = StringBuffer();
    final code = await runSubtitleCommand(
        rest: ['show', '没这条'], dataDir: dataDir, err: err);
    expect(code, exitNotFound);
  });
}
