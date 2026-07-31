import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/features/tasks/task_filter.dart';

RenewTask _task(String id, String name, RenewTaskStatus status,
        {String? error}) =>
    RenewTask(
      id: id,
      name: name,
      sourcePath: '/v/$id.mp4',
      status: status,
      analysisError: error,
      createdAt: DateTime.utc(2026, 7, 31),
      updatedAt: DateTime.utc(2026, 7, 31),
    );

final _tasks = [
  _task('hkv1', '滴露_植源喷雾_XCT', RenewTaskStatus.awaitingCut),
  _task('hkv2', '卫仕洗衣液_ZJD', RenewTaskStatus.picking),
  _task('hkv3', '舒肤佳_内核', RenewTaskStatus.exported),
  _task('hkv4', '滴露_消毒液', RenewTaskStatus.analyzing),
  _task('hkv5', '立白_卫仕', RenewTaskStatus.analyzing, error: '网络超时'),
];

List<RenewTask> _filter({String query = '', TaskFilter filter = TaskFilter.all}) =>
    applyTaskFilter(_tasks, query: query, filter: filter);

void main() {
  group('按名称搜索', () {
    test('子串匹配，不要求从头匹配', () {
      expect(_filter(query: '洗衣液').map((t) => t.id), ['hkv2']);
    });

    test('大小写与首尾空格都不影响结果', () {
      expect(_filter(query: '  XCT  ').map((t) => t.id), ['hkv1']);
      expect(_filter(query: 'xct').map((t) => t.id), ['hkv1'],
          reason: '用户不会记得原文件名里是大写还是小写');
    });

    test('空查询返回全部，不是返回空', () {
      expect(_filter(query: '   '), hasLength(_tasks.length));
    });

    test('按任务 id 也能搜到——设计稿的搜索框写的就是「任务名 / ID」', () {
      expect(_filter(query: 'hkv3').map((t) => t.id), ['hkv3']);
    });

    test('搜不到时返回空列表，由界面负责给出说明', () {
      expect(_filter(query: '不存在的名字'), isEmpty);
    });
  });

  group('按状态筛选', () {
    test('全部', () {
      expect(_filter(filter: TaskFilter.all), hasLength(5));
    });

    test('待处理 = 待切分确认 + 选材中（该我动手的）', () {
      expect(_filter(filter: TaskFilter.todo).map((t) => t.id),
          ['hkv1', 'hkv2']);
    });

    test('进行中只包含真正在跑的，不含已失败的', () {
      final ids = _filter(filter: TaskFilter.running).map((t) => t.id);

      expect(ids, ['hkv4']);
      expect(ids, isNot(contains('hkv5')),
          reason: '失败的任务挂在「进行中」里，用户会一直等一个永远不会完成的东西');
    });

    test('有问题 = 分析失败', () {
      expect(_filter(filter: TaskFilter.failed).map((t) => t.id), ['hkv5']);
    });

    test('已完成 = 已导出', () {
      expect(_filter(filter: TaskFilter.done).map((t) => t.id), ['hkv3']);
    });
  });

  group('搜索与筛选叠加', () {
    test('两个条件同时生效', () {
      expect(_filter(query: '滴露', filter: TaskFilter.todo).map((t) => t.id),
          ['hkv1']);
    });
  });

  group('筛选项文案', () {
    test('每个筛选项都有中文标签，且不含技术黑话', () {
      for (final f in TaskFilter.values) {
        expect(f.label, isNotEmpty);
        expect(f.label, isNot(contains('status')));
      }
    });

    test('顺序按「我最常看什么」排：全部 → 待处理 在最前', () {
      expect(TaskFilter.values.first, TaskFilter.all);
      expect(TaskFilter.values[1], TaskFilter.todo);
    });
  });

  group('原列表不被改动', () {
    test('筛选返回新列表，不就地排序或删元素', () {
      final before = List.of(_tasks);
      _filter(query: '滴露');

      expect(_tasks, equals(before));
    });
  });
}
