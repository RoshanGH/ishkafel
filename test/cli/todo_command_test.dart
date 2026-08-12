import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/cli/cli_output.dart';
import 'package:ishkafel/cli/commands/todo_command.dart';
import 'package:ishkafel/cli/external_steps.dart';
import 'package:ishkafel/core/analysis/analysis_pipeline.dart';
import 'package:ishkafel/core/analysis/providers.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/storage/file_task_repository.dart';

/// `ishkafel todo <task>` —— 把欠着的那件外包待办再吐一遍。
///
/// 存在的理由：`analyze --external=...` 停下来时把待办打在标准输出上，
/// **那是唯一的一份**。丢了就只剩重跑 analyze 一条路，而那会重跑一遍 ASR，
/// 既花钱又慢。东西本来就在盘上，取回来是应该的。
void main() {
  late Directory dir;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('ishkafel_todo_');
    await FileTaskRepository(dir).save(RenewTask(
      id: 't1',
      name: '测试',
      sourcePath: '/tmp/a.mp4',
      status: RenewTaskStatus.analyzing,
      createdAt: DateTime.utc(2026, 8, 12),
      updatedAt: DateTime.utc(2026, 8, 12),
    ));
  });
  tearDown(() => dir.deleteSync(recursive: true));

  void stash(Set<ExternalStep> pending) => saveAnalysisState(
        dir,
        't1',
        AnalysisState(
          prepared: const PreparedAnalysis(
            sentences: [
              AsrSentence(startMs: 0, endMs: 900, text: '第一句。'),
              AsrSentence(startMs: 900, endMs: 1800, text: '第二句。'),
            ],
            valleys: [900],
            shotBounds: [0, 900, 1800],
          ),
          pending: pending,
        ),
      );

  test('没有这个任务就直说', () async {
    final err = StringBuffer();
    final code = await runTodoCommand(rest: ['不存在'], dataDir: dir, err: err);
    expect(code, exitNotFound);
    expect(err.toString(), contains('没有这个任务'));
  });

  test('没欠着东西不是错误，是一种状态——说清楚，退出码 0', () async {
    final out = StringBuffer();
    final code = await runTodoCommand(rest: ['t1'], dataDir: dir, out: out);
    expect(code, 0);
    final json = jsonDecode(out.toString()) as Map;
    expect(json['status'], 'none');
    expect(json['why'], contains('没有欠着'));
  });

  test('欠着切分就把切分待办原样吐出来，句子一句不少', () async {
    stash({ExternalStep.segment});
    final out = StringBuffer();
    final code = await runTodoCommand(rest: ['t1'], dataDir: dir, out: out);
    expect(code, 0);

    final todo = (jsonDecode(out.toString()) as Map)['todo'] as Map;
    expect(todo['kind'], 'segment');
    final sentences = (todo['input'] as Map)['sentences'] as List;
    expect(sentences, hasLength(2));
    expect((sentences.first as Map)['text'], '第一句。');
    // 做完怎么交回来必须一起给，否则它还得去翻文档
    expect(todo['apply'], contains('apply segment t1'));
  });

  test('两步都欠着时先给切分——打标要等单元出来才做得了', () async {
    stash({ExternalStep.segment, ExternalStep.tag});
    final out = StringBuffer();
    await runTodoCommand(rest: ['t1'], dataDir: dir, out: out);
    expect(((jsonDecode(out.toString()) as Map)['todo'] as Map)['kind'],
        'segment');
  });
}
