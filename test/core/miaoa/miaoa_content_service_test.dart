import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/miaoa/miaoa_content_service.dart';
import 'package:ishkafel/core/miaoa/miaoa_gateway.dart';
import 'package:ishkafel/core/miaoa/miaoa_tag_service.dart' show MiaoaException;

/// 取自真实 `miaoa content search --type storyboard --json` 的返回结构
/// （字段名与嵌套层级照抄，值做了精简）
String _realShapedResponse({int records = 1, int total = 982}) {
  final items = List.generate(records, (i) => {
        'id': 76555 + i,
        'name': '滴露_消毒液_$i',
        'sceneDescription': '在明亮的室内，一只手拿着一瓶滴露消毒液。',
        'publicTags': [
          {'id': 1, 'name': '竖屏', 'tagGroupName': '画面格式'},
          {'id': 2, 'name': '成分展示', 'tagGroupName': '分镜画面'},
        ],
        'aiTags': [
          {'id': 3, 'name': '产品亮相', 'tagGroupName': '分镜目的'},
          // 与 publicTags 重名，应被去重
          {'id': 4, 'name': '竖屏', 'tagGroupName': '画面格式'},
        ],
        'mediaFile': {
          'id': 84843,
          'fileKey': 'prod/tenant-19/x$i.mov',
          'thumbnailUrl': 'https://cdn/x$i.jpg?sign=abc',
          'previewUrl': 'https://cdn/x$i.mov?sign=abc',
          // 真机实测：分镜库这两个字段恒为 null
          'duration': null,
          'resolution': null,
        },
      });
  return jsonEncode({'records': items, 'total': total, 'current': 1});
}

MiaoaContentService _service(
  List<List<String>> capturedArgs, {
  String? stdout,
  String stderr = '',
  int exitCode = 0,
}) =>
    MiaoaContentService(gateway: MiaoaGateway(run: (bin, args) async {
      capturedArgs.add(args);
      return ProcessResult(1, exitCode, stdout ?? _realShapedResponse(), stderr);
    }, binary: 'miaoa'));

void main() {
  group('检索范围限定在一个项目内', () {
    test('三种模式都带上 --projects', () async {
      final calls = <List<String>>[];
      final service = _service(calls);

      await service.searchByTags(tagIds: [1], projectIds: [104]);
      await service.searchByDescription(keyword: '手持特写', projectIds: [104]);
      await service.searchByImage(fileKey: 'k', projectIds: [104]);

      for (final args in calls) {
        expect(args, containsAllInOrder(['--projects', '104']),
            reason: '素材库四万多条分镜横跨几十个项目，'
                '不限项目搜出来的大多不是这条片子能用的');
      }
    });

    test('多个项目用逗号连起来', () async {
      final calls = <List<String>>[];
      await _service(calls).searchByTags(tagIds: [1], projectIds: [104, 139]);

      expect(calls.single, containsAllInOrder(['--projects', '104,139']));
    });

    test('不限项目时整个不传这个参数', () async {
      final calls = <List<String>>[];
      await _service(calls).searchByTags(tagIds: [1]);

      expect(calls.single, isNot(contains('--projects')),
          reason: 'CLI 把「不传」解释成我的全部项目聚合，'
              '传空串反而会被当成非法值');
    });

    test('项目越权时把 CLI 那句话翻译成能据以行动的中文', () async {
      final calls = <List<String>>[];
      // 真机实测：这个错误写在 stdout（JSON），退出码 2，stderr 是空的
      final service = _service(
        calls,
        exitCode: 2,
        stdout: jsonEncode({
          'error': {
            'message': '以下项目不属于「我的项目」，不能作为 --projects/--project 值：[999999]。'
          },
          'ok': false,
        }),
      );

      expect(
        () => service.searchByTags(tagIds: [1], projectIds: [999999]),
        throwsA(isA<MiaoaException>().having((e) => e.message, 'message',
            contains('不在你可用的项目范围内'))),
        reason: '只看 stderr 会把这条讲清楚了的报错降级成「请稍后重试」，'
            '用户不知道该换项目',
      );
    });
  });

  group('候选素材检索：三种互斥模式对应的 CLI 参数', () {
    test('标签精确筛：--public-tag 与匹配模式', () async {
      final calls = <List<String>>[];
      await _service(calls).searchByTags(tagIds: [1279, 136], mode: 'and');

      final args = calls.single;
      expect(args, containsAllInOrder(['--type', 'storyboard']),
          reason: '替换的是视觉镜头，对应 miaoa 的分镜库；成片库是整条片子');
      expect(args, containsAllInOrder(['--public-tag', '1279,136']));
      expect(args, containsAllInOrder(['--public-mode', 'and']));
      expect(args, contains('--json'));
    });

    test('画面描述语义搜：--by content', () async {
      final calls = <List<String>>[];
      await _service(calls).searchByDescription(keyword: ' 手持产品特写 ');

      final args = calls.single;
      expect(args, containsAllInOrder(['--keyword', '手持产品特写']),
          reason: '首尾空白应清掉，否则语义检索命中率会受影响');
      expect(args, containsAllInOrder(['--by', 'content']));
    });

    test('按名称搜：--by name（标签筛不到时的兜底路子）', () async {
      // 主路径是拿参考镜头的画面描述去找像的；找不到时人会说
      // 「我知道妙啊里有那条片子」，直接按文件名捞出来
      final calls = <List<String>>[];
      await _service(calls).searchByName(keyword: ' 滴露_植源喷雾 ');

      final args = calls.single;
      expect(args, containsAllInOrder(['--keyword', '滴露_植源喷雾']));
      expect(args, containsAllInOrder(['--by', 'name']));
      expect(args, containsAllInOrder(['--type', 'storyboard']));
    });

    test('按名称搜：名字为空直接拒绝，不拿空关键词去问服务端', () async {
      expect(() => _service([]).searchByName(keyword: '  '),
          throwsA(isA<MiaoaException>()));
    });

    test('首帧以图搜图：--like-image 传 OSS key', () async {
      final calls = <List<String>>[];
      await _service(calls).searchByImage(fileKey: 'prod/tenant-19/x.mov');

      expect(calls.single,
          containsAllInOrder(['--like-image', 'prod/tenant-19/x.mov']));
    });

    test('台词语义搜：--by voiceover（Round 2 三维度之一）', () async {
      final calls = <List<String>>[];
      await _service(calls).searchByVoiceover(keyword: ' 再不买就恢复 ');

      final args = calls.single;
      expect(args, containsAllInOrder(['--keyword', '再不买就恢复']));
      expect(args, containsAllInOrder(['--by', 'voiceover']));
    });

    test('标签是所有维度的统一外部约束：keyword 维度可叠 --public-tag',
        () async {
      final calls = <List<String>>[];
      final service = _service(calls);
      await service.searchByDescription(keyword: '厨房', tagIds: [7, 9]);
      await service.searchByVoiceover(keyword: '词', tagIds: [7]);
      await service.searchByImage(fileKey: 'k', tagIds: [9]);

      for (final args in calls) {
        expect(args, contains('--public-tag'),
            reason: '标签约束要贴在每一种检索维度上');
      }
      expect(calls[0], containsAllInOrder(['--public-tag', '7,9']));
      expect(calls[0], containsAllInOrder(['--public-mode', 'or']));
      expect(calls[1], containsAllInOrder(['--public-tag', '7']));
      expect(calls[2], containsAllInOrder(['--public-tag', '9']));
    });

    test('不带标签约束时不发 --public-tag（别把空约束发给服务端）',
        () async {
      final calls = <List<String>>[];
      await _service(calls).searchByVoiceover(keyword: '词');
      expect(calls.single, isNot(contains('--public-tag')));
    });

    test('空输入直接拒绝，不发起无意义的检索', () async {
      final calls = <List<String>>[];
      final service = _service(calls);

      await expectLater(
          service.searchByTags(tagIds: const []), throwsA(isA<MiaoaException>()));
      await expectLater(service.searchByDescription(keyword: '   '),
          throwsA(isA<MiaoaException>()));
      await expectLater(service.searchByVoiceover(keyword: ' '),
          throwsA(isA<MiaoaException>()));
      await expectLater(
          service.searchByImage(fileKey: ''), throwsA(isA<MiaoaException>()));
      expect(calls, isEmpty);
    });
  });

  group('解析真实返回结构', () {
    test('取出候选卡需要的字段，标签合并去重', () async {
      final page = await _service([]).searchByTags(tagIds: [1]);

      expect(page.total, 982);
      final item = page.items.single;
      expect(item.id, 76555);
      expect(item.name, '滴露_消毒液_0');
      expect(item.sceneDescription, contains('滴露消毒液'));
      expect(item.thumbnailUrl, startsWith('https://cdn/'));
      expect(item.fileKey, 'prod/tenant-19/x0.mov');
      expect(item.tags, ['竖屏', '成分展示', '产品亮相'],
          reason: '公共标签在前（人工确认过的更可信），与 AI 标签合并后去重');
    });

    test('候选列表是只读的，不会被调用方就地改坏', () async {
      final page = await _service([]).searchByTags(tagIds: [1]);
      expect(() => page.items.clear(), throwsUnsupportedError);
      expect(() => page.items.first.tags.add('x'), throwsUnsupportedError);
    });
  });

  group('外部数据不可信', () {
    test('单条畸形只跳过该条，不牵连整批，并如实计数', () async {
      final payload = jsonEncode({
        'records': [
          {'id': 1, 'name': 'ok', 'mediaFile': <String, Object?>{}},
          {'id': 'not-an-int'}, // 畸形
          'plain string', // 畸形
          {'name': '缺少 id'}, // 畸形
        ],
        'total': 4,
      });
      final page =
          await _service([], stdout: payload).searchByTags(tagIds: [1]);

      expect(page.items, hasLength(1));
      expect(page.skipped, 3,
          reason: '静默丢弃会让用户以为「素材库里就这些」，必须如实上报');
    });

    test('非 JSON 返回给人话提示，而不是把 FormatException 摊给用户', () async {
      final service = _service([], stdout: '<html>502 Bad Gateway</html>');
      await expectLater(
        service.searchByTags(tagIds: [1]),
        throwsA(isA<MiaoaException>().having((e) => e.toString(), 'message',
            contains('无法识别'))),
      );
    });

    test('records 不是数组时不崩', () async {
      final service =
          _service([], stdout: jsonEncode({'records': {'a': 1}, 'total': 0}));
      await expectLater(
          service.searchByTags(tagIds: [1]), throwsA(isA<MiaoaException>()));
    });
  });

  group('失败提示要让用户知道下一步做什么', () {
    Future<void> expectMessage(String stderr, String expected) async {
      final service = _service([], exitCode: 1, stderr: stderr);
      await expectLater(
        service.searchByTags(tagIds: [1]),
        throwsA(isA<MiaoaException>()
            .having((e) => e.toString(), 'message', contains(expected))),
      );
    }

    test('未登录 → 指出要跑 auth login（不自动重试）', () =>
        expectMessage('HTTP 401 Unauthorized', 'miaoa auth login'));

    test('无权限 → 指向管理员', () =>
        expectMessage('HTTP 403 Forbidden', '权限'));

    test('CLI 未安装 → 指出要先安装', () =>
        expectMessage('No such file or directory', '未找到 miaoa'));

    test('超时 → 指向网络', () => expectMessage('operation timed out', '网络'));
  });

  group('取单条素材：负数 id 也要能取到', () {
    test('id 放在 `--` 后面——不然负数会被命令行当成参数名', () async {
      final calls = <List<String>>[];
      final service = _service(calls,
          stdout: '{"id":-19954,"name":"x","mediaFile":{"id":1,'
              '"fileKey":"k","previewUrl":"https://cdn/x.mov"}}');

      final m = await service.fetchById(-19954);

      expect(m?.id, -19954);
      final args = calls.single;
      expect(args.last, '-19954',
          reason: '真机上直接传 -19954 被解析成参数：'
              "error: unexpected argument '-1' found");
      expect(args[args.length - 2], '--');
    });

    test('正数 id 走的是同一条路，不搞两套', () async {
      final calls = <List<String>>[];
      await _service(calls,
              stdout: '{"id":76555,"name":"x","mediaFile":{"id":1,'
                  '"fileKey":"k","previewUrl":"https://cdn/x.mov"}}')
          .fetchById(76555);

      expect(calls.single.last, '76555');
      expect(calls.single[calls.single.length - 2], '--');
    });
  });

}
