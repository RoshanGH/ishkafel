import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/miaoa/miaoa_tag_service.dart';

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
      final service = MiaoaTagService(
          run: (_, _) async => ProcessResult(1, 0, groupListJson, ''));
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
      final service = MiaoaTagService(run: (exe, args) async {
        usedExe = exe;
        usedArgs = args;
        return ProcessResult(1, 0, groupListJson, '');
      });
      await service.listGroups();
      expect(usedExe, 'miaoa');
      expect(usedArgs, ['tag', 'group', 'list', '--scope', 'tenant', '--json']);
    });

    test('非零退出码抛 MiaoaException 且带 stderr', () async {
      final service = MiaoaTagService(
          run: (_, _) async => ProcessResult(1, 1, '', '未登录'));
      expect(
        () => service.listGroups(),
        throwsA(isA<MiaoaException>()
            .having((e) => e.message, 'message', contains('未登录'))),
      );
    });

    test('stdout 非合法 JSON 抛 MiaoaException', () async {
      final service = MiaoaTagService(
          run: (_, _) async => ProcessResult(1, 0, 'not json', ''));
      expect(
        () => service.listGroups(),
        throwsA(isA<MiaoaException>()),
      );
    });
  });

  group('MiaoaTagService.listTags', () {
    test('解析实测 fixture 为 TagInfo 列表', () async {
      final service = MiaoaTagService(
          run: (_, _) async => ProcessResult(1, 0, tagListJson, ''));
      final tags = await service.listTags(1281);
      expect(tags.length, 2);
      expect(tags.first.id, 18519);
      expect(tags.first.name, '产品杀菌率展示');
    });

    test('命令参数正确', () async {
      late List<String> usedArgs;
      final service = MiaoaTagService(run: (exe, args) async {
        usedArgs = args;
        return ProcessResult(1, 0, tagListJson, '');
      });
      await service.listTags(1281);
      expect(usedArgs, ['tag', 'list', '--group', '1281', '--json']);
    });

    test('非零退出码抛 MiaoaException 且带 stderr', () async {
      final service = MiaoaTagService(
          run: (_, _) async => ProcessResult(1, 1, '', '分组不存在'));
      expect(
        () => service.listTags(1281),
        throwsA(isA<MiaoaException>()
            .having((e) => e.message, 'message', contains('分组不存在'))),
      );
    });

    test('stdout 非合法 JSON 抛 MiaoaException', () async {
      final service = MiaoaTagService(
          run: (_, _) async => ProcessResult(1, 0, '{invalid', ''));
      expect(
        () => service.listTags(1281),
        throwsA(isA<MiaoaException>()),
      );
    });
  });
}
