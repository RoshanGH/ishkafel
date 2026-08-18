import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/log/app_log.dart';
import 'package:ishkafel/core/miaoa/miaoa_tag_service.dart';
import 'package:ishkafel/core/miaoa/miaoa_failure.dart';
import 'package:ishkafel/core/miaoa/miaoa_gateway.dart';

/// Step 0 实测样例（截断自真实 CLI 输出，字段与顺序保持一致）：
/// miaoa tag group list --scope tenant --json
/// [{"id":396,"groupName":"素材形态","materialType":"IMAGE","tagType":"AI","tags":null},
///  {"id":365,"groupName":"图片用途","materialType":"IMAGE","tagType":"AI","tags":null}, ...]
const groupListJson = '''
[
  {"id":396,"groupName":"素材形态","materialType":"IMAGE","tagType":"AI","tags":null},
  {"id":365,"groupName":"图片用途","materialType":"IMAGE","tagType":"AI","tags":null}
]
''';

/// miaoa tag list --group 1281 --json
/// [{"id":18519,"tagGroupId":1281,"tagName":"产品杀菌率展示","tagType":"TENANT","isEnabled":true},
///  {"id":18528,"tagGroupId":1281,"tagName":"live","tagType":"TENANT","isEnabled":true}, ...]
const tagListJson = '''
[
  {"id":18519,"tagGroupId":1281,"tagName":"产品杀菌率展示","tagType":"TENANT","isEnabled":true},
  {"id":18528,"tagGroupId":1281,"tagName":"live","tagType":"TENANT","isEnabled":true}
]
''';

void main() {
  group('MiaoaTagService.listGroups', () {
    test('解析实测 fixture 为 TagGroup 列表', () async {
      final service = MiaoaTagService(gateway: MiaoaGateway(run: (_, _) async => ProcessResult(1, 0, groupListJson, ''), binary: 'miaoa'));
      final groups = await service.listGroups();
      expect(groups.length, 2);
      expect(groups.first.id, 396);
      expect(groups.first.name, '素材形态');
      expect(groups.first.materialType, 'IMAGE');
      expect(groups.first.tagType, 'AI');
    });

    test('命令参数正确', () async {
      late String usedExe;
      late List<String> usedArgs;
      final service = MiaoaTagService(gateway: MiaoaGateway(run: (exe, args) async {
        usedExe = exe;
        usedArgs = args;
        return ProcessResult(1, 0, groupListJson, '');
      }, binary: 'miaoa'));
      await service.listGroups();
      expect(usedExe, 'miaoa');
      expect(usedArgs,
          ['tag', 'group', 'list', '--scope', 'tenant', '--include-tags', '--json']);
      expect(usedArgs, contains('--include-tags'),
          reason: '一次把组内标签也带回来（127 组 / 2461 标签共约 210KB），'
              '省掉「每选一个组再拉一次」的往返，也让新建向导能按标签名搜组');
    });

    test('带回来的标签被解析出来', () async {
      const withTags = '''
[
  {"id":1,"groupName":"画面类型","materialType":"STORYBOARD","tagType":"AI",
   "tags":[{"id":11,"tagName":"真人口播"},{"id":12,"tagName":"产品特写"}]}
]
''';
      final service = MiaoaTagService(gateway: MiaoaGateway(run: (_, _) async => ProcessResult(1, 0, withTags, ''), binary: 'miaoa'));

      final groups = await service.listGroups();

      expect(groups.single.tags, ['真人口播', '产品特写']);
    });

    test('没有 tags 字段时当作空，不丢掉整个标签组', () async {
      const noTags = '''
[{"id":1,"groupName":"画面类型","materialType":"STORYBOARD","tagType":"AI"}]
''';
      final service = MiaoaTagService(gateway: MiaoaGateway(run: (_, _) async => ProcessResult(1, 0, noTags, ''), binary: 'miaoa'));

      final groups = await service.listGroups();

      expect(groups, hasLength(1));
      expect(groups.single.tags, isEmpty);
    });

    test('个别标签条目非法只跳过它，不牵连整个标签组', () async {
      const partial = '''
[
  {"id":1,"groupName":"画面类型","materialType":"STORYBOARD","tagType":"AI",
   "tags":[{"id":11,"tagName":"真人口播"},{"id":12},{"tagName":123}]}
]
''';
      final service = MiaoaTagService(gateway: MiaoaGateway(run: (_, _) async => ProcessResult(1, 0, partial, ''), binary: 'miaoa'));

      final groups = await service.listGroups();

      expect(groups.single.tags, ['真人口播']);
    });

    test('非零退出码抛已分类的 MiaoaException——stderr 原文进日志，用户看引导', () async {
      final service = MiaoaTagService(gateway: MiaoaGateway(run: (_, _) async => ProcessResult(1, 1, '', '未登录'), binary: 'miaoa'));
      expect(
        () => service.listGroups(),
        throwsA(isA<MiaoaException>()
            .having((e) => e.kind, 'kind', MiaoaFailureKind.unauthorized)
            .having((e) => e.message, 'message', contains('重新登录'))),
      );
    });

    test('stdout 非合法 JSON 抛 MiaoaException', () async {
      final service = MiaoaTagService(gateway: MiaoaGateway(run: (_, _) async => ProcessResult(1, 0, 'not json', ''), binary: 'miaoa'));
      expect(
        () => service.listGroups(),
        throwsA(isA<MiaoaException>()),
      );
    });
  });

  group('MiaoaTagService.listTags', () {
    test('解析实测 fixture 为 TagInfo 列表', () async {
      final service = MiaoaTagService(gateway: MiaoaGateway(run: (_, _) async => ProcessResult(1, 0, tagListJson, ''), binary: 'miaoa'));
      final tags = await service.listTags(1281);
      expect(tags.length, 2);
      expect(tags.first.id, 18519);
      expect(tags.first.name, '产品杀菌率展示');
    });

    test('命令参数正确', () async {
      late List<String> usedArgs;
      final service = MiaoaTagService(gateway: MiaoaGateway(run: (exe, args) async {
        usedArgs = args;
        return ProcessResult(1, 0, tagListJson, '');
      }, binary: 'miaoa'));
      await service.listTags(1281);
      expect(usedArgs, ['tag', 'list', '--group', '1281', '--json']);
    });

    test('非零退出码抛已分类的 MiaoaException——404 类给「已不存在」引导', () async {
      final service = MiaoaTagService(gateway: MiaoaGateway(run: (_, _) async => ProcessResult(1, 1, '', '分组不存在'), binary: 'miaoa'));
      expect(
        () => service.listTags(1281),
        throwsA(isA<MiaoaException>()
            .having((e) => e.kind, 'kind', MiaoaFailureKind.notFound)
            .having((e) => e.message, 'message', contains('找不到'))),
      );
    });

    test('stdout 非合法 JSON 抛 MiaoaException', () async {
      final service = MiaoaTagService(gateway: MiaoaGateway(run: (_, _) async => ProcessResult(1, 0, '{invalid', ''), binary: 'miaoa'));
      expect(
        () => service.listTags(1281),
        throwsA(isA<MiaoaException>()),
      );
    });
  });

  group('CLI 输出不可信：字段缺失/类型不符都给人话中文错误', () {
    late List<String> logs;

    setUp(() {
      logs = [];
      final previous = AppLog.sink;
      AppLog.sink = logs.add;
      addTearDown(() => AppLog.sink = previous);
    });

    MiaoaTagService serviceReturning(Object? stdout) => MiaoaTagService(gateway: MiaoaGateway(run: (_, _) async => ProcessResult(1, 0, stdout, ''), binary: 'miaoa'));

    test('stdout 是字节流（stdoutEncoding: null 时的真实类型）也能解析', () async {
      final service = serviceReturning(utf8.encode(groupListJson));
      final groups = await service.listGroups();
      expect(groups.length, 2);
      expect(groups.first.name, '素材形态');
    });

    test('stdout 既不是字符串也不是字节流 → MiaoaException 而不是 TypeError', () async {
      // 网关把认不出的输出类型当空文本，落到「非法 JSON」这条中文路径上
      await expectLater(
        serviceReturning(42).listGroups(),
        throwsA(isA<MiaoaException>()
            .having((e) => e.message, 'message', contains('JSON'))),
      );
    });

    test('顶层不是数组 → MiaoaException', () async {
      await expectLater(
        serviceReturning('{"items":[]}').listGroups(),
        throwsA(isA<MiaoaException>()
            .having((e) => e.message, 'message', contains('数组'))),
      );
    });

    test('个别条目非法（非对象/缺字段/类型错）时跳过，合法条目照常返回', () async {
      const json = '''
[
  "not-an-object",
  {"groupName":"缺 id","materialType":"IMAGE","tagType":"AI"},
  {"id":"396","groupName":"id 类型错","materialType":"IMAGE","tagType":"AI"},
  {"id":365,"groupName":"合法组","materialType":"VIDEO","tagType":"TENANT"}
]
''';
      final groups = await serviceReturning(json).listGroups();
      expect(groups.length, 1);
      expect(groups.single.id, 365);
      expect(groups.single.name, '合法组');
      expect(logs.join(), contains('3'));
    });

    test('全部条目非法 → MiaoaException 而不是静默返回空', () async {
      await expectLater(
        serviceReturning('[{"groupName":"缺 id"},"x"]').listGroups(),
        throwsA(isA<MiaoaException>()
            .having((e) => e.message, 'message', contains('全部'))),
      );
    });

    test('空数组是合法结果，返回空列表', () async {
      expect(await serviceReturning('[]').listGroups(), isEmpty);
      expect(await serviceReturning('[]').listTags(1), isEmpty);
    });

    test('listTags 同样跳过非法条目', () async {
      const json = '''
[
  {"id":18519,"tagName":"产品杀菌率展示"},
  {"id":18528},
  {"tagName":"缺 id"}
]
''';
      final tags = await serviceReturning(json).listTags(1281);
      expect(tags.length, 1);
      expect(tags.single.name, '产品杀菌率展示');
    });

    test('返回的列表不可变，不把可变集合暴露给外部', () async {
      final groups = await serviceReturning(groupListJson).listGroups();
      expect(
        () => groups.add(const TagGroup(
            id: 1, name: 'x', materialType: 'IMAGE', tagType: 'AI')),
        throwsUnsupportedError,
      );
      final tags = await serviceReturning(tagListJson).listTags(1);
      expect(() => tags.add(const TagInfo(id: 1, name: 'x')),
          throwsUnsupportedError);
    });
  });
}
