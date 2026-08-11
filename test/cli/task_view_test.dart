import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/cli/task_view.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/core/models/video_info.dart';

/// 给 Agent 看的任务视图。
///
/// 原则：**给事实，不给结论**。每段多长、台词是什么、打了哪些标签——都如实
/// 摆出来；「该挑哪个」是调用方的判断（见 spec「软件提供事实与保护，
/// skill 提供方法论」）。
void main() {
  RenewTask taskWith({List<SemanticUnit>? units, String? error}) => RenewTask(
        id: 'abc',
        name: '测试任务',
        sourcePath: '/tmp/a.mp4',
        status: RenewTaskStatus.ready,
        createdAt: DateTime.utc(2026, 8, 11),
        updatedAt: DateTime.utc(2026, 8, 11),
        units: units,
        analysisError: error,
        videoInfo: const VideoInfo(
          width: 1080,
          height: 1920,
          duration: Duration(milliseconds: 30000),
          fps: 30,
          fileSizeBytes: 100,
        ),
      );

  test('带上基本信息与片长', () {
    final json = taskToJson(taskWith());
    expect(json['id'], 'abc');
    expect(json['name'], '测试任务');
    expect(json['status'], 'ready');
    expect(json['durationMs'], 30000);
    expect(json['fps'], 30);
    expect(json['sourcePath'], '/tmp/a.mp4');
  });

  test('单元与镜头逐条列出，带时间、台词、标签', () {
    final json = taskToJson(taskWith(units: [
      SemanticUnit(
        index: 0,
        startMs: 0,
        endMs: 5000,
        transcript: '第一句',
        tags: const ['促单'],
        shots: const [
          Shot(startMs: 0, endMs: 2000),
          Shot(startMs: 2000, endMs: 5000),
        ],
      ),
    ]));

    final units = json['units'] as List;
    expect(units, hasLength(1));
    final u = units.single as Map;
    expect(u['index'], 0);
    expect(u['startMs'], 0);
    expect(u['endMs'], 5000);
    expect(u['durationMs'], 5000);
    expect(u['transcript'], '第一句');
    expect(u['tags'], ['促单']);

    final shots = u['shots'] as List;
    expect(shots, hasLength(2));
    expect((shots.first as Map)['index'], 0);
    expect((shots.first as Map)['durationMs'], 2000);
    expect((shots.last as Map)['startMs'], 2000);
  });

  test('还没分析完时如实说，而不是拿空数组冒充「没有单元」', () {
    final json = taskToJson(taskWith(units: null));
    expect(json['analyzed'], isFalse);
    expect(json['units'], isNull);
  });

  test('分析出错时把原因带出来——调用方要能分辨「还在跑」和「跑挂了」', () {
    final json = taskToJson(taskWith(error: '转写失败'));
    expect(json['analysisError'], '转写失败');
  });

  test('导出历史也给——调用方要知道导过没有、导到哪儿', () {
    final json = taskToJson(taskWith());
    expect(json['exports'], isA<List>());
  });
}
