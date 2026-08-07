import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/miaoa/candidate_probe.dart';
import 'package:ishkafel/core/miaoa/miaoa_content_service.dart';
import 'package:ishkafel/features/picking/candidate_search_controller.dart';

/// miaoa 检索的假返回：[count] 条候选，都有可探测的预览地址
String _searchJson(int count, {int? total}) => jsonEncode({
      'total': total ?? count,
      'records': [
        for (var i = 0; i < count; i++)
          {
            'id': 100 + i,
            'name': '候选 $i',
            'sceneDescription': '画面 $i',
            'mediaFile': {
              'thumbnailUrl': 'https://example.com/$i.jpg',
              'previewUrl': 'https://example.com/$i.mp4',
              'fileKey': 'oss/$i.mp4',
            },
          },
      ],
    });

ProcessResult _ok(String stdout) => ProcessResult(1, 0, stdout, '');

/// ffprobe 的假输出（6.8 秒、1080×1920）
const _probeStdout = 'width=1080\nheight=1920\nduration=6.840000\n';

void main() {
  group('检索结果装载', () {
    test('成功：先出候选卡（规格标为探测中），再逐条填规格', () async {
      final probeGate = Completer<void>();
      final controller = CandidateSearchController(
        service: MiaoaContentService(run: (_, _) async => _ok(_searchJson(2))),
        probe: CandidateProbe(run: (_, _) async {
          await probeGate.future;
          return _ok(_probeStdout);
        }),
      );

      final search = controller.searchByDescription('喷雾');
      await Future<void>.delayed(Duration.zero);
      expect(controller.status, CandidateSearchStatus.ready);
      expect(controller.entries, hasLength(2));
      expect(controller.entries.every((e) => e.probing), isTrue,
          reason: '规格还没探完时必须是「探测中」占位，不能是空白');
      expect(controller.entries.first.spec, isNull);

      probeGate.complete();
      await search;
      expect(controller.entries.every((e) => e.probing), isFalse);
      expect(controller.entries.first.spec!.durationMs, 6840);
    });

    test('探测失败的那一条只是没有规格，不影响其余候选也不报错', () async {
      var call = 0;
      final controller = CandidateSearchController(
        service: MiaoaContentService(run: (_, _) async => _ok(_searchJson(2))),
        probe: CandidateProbe(
            run: (_, _) async =>
                call++ == 0 ? ProcessResult(1, 1, '', 'boom') : _ok(_probeStdout)),
      );

      await controller.searchByDescription('喷雾');
      expect(controller.status, CandidateSearchStatus.ready);
      expect(controller.entries[0].spec, isNull);
      expect(controller.entries[0].probing, isFalse,
          reason: '探测已结束，不能永远停在「探测中」');
      expect(controller.entries[1].spec, isNotNull);
    });

    test('规格探测并发有上限，不会一次把二十条全打出去', () async {
      var inFlight = 0;
      var peak = 0;
      final controller = CandidateSearchController(
        service: MiaoaContentService(run: (_, _) async => _ok(_searchJson(20))),
        probe: CandidateProbe(run: (_, _) async {
          inFlight++;
          if (inFlight > peak) peak = inFlight;
          await Future<void>.delayed(const Duration(milliseconds: 1));
          inFlight--;
          return _ok(_probeStdout);
        }),
        probeConcurrency: 4,
      );

      await controller.searchByDescription('喷雾');
      expect(peak, lessThanOrEqualTo(4));
      expect(peak, greaterThan(1), reason: '串行探测 20 条要一分钟，必须并发');
      expect(controller.entries.where((e) => e.spec != null), hasLength(20));
    });

    test('0 条结果是正常状态（引导语由页面按检索方式给），不是失败', () async {
      final controller = CandidateSearchController(
        service: MiaoaContentService(run: (_, _) async => _ok(_searchJson(0))),
        probe: CandidateProbe(run: (_, _) async => _ok(_probeStdout)),
      );
      await controller.searchByTags(tagIds: const [7]);
      expect(controller.status, CandidateSearchStatus.ready);
      expect(controller.entries, isEmpty);
      expect(controller.failureMessage, isNull);
    });

    test('总数与被跳过的畸形条目如实带出（不静默丢弃）', () async {
      final json = jsonEncode({
        'total': 99,
        'records': [
          {'id': 1, 'mediaFile': <String, dynamic>{}},
          'garbage',
        ],
      });
      final controller = CandidateSearchController(
        service: MiaoaContentService(run: (_, _) async => _ok(json)),
        probe: CandidateProbe(run: (_, _) async => _ok(_probeStdout)),
      );
      await controller.searchByDescription('喷雾');
      expect(controller.total, 99);
      expect(controller.skipped, 1);
    });
  });

  group('失败提示：服务层的中文原样透出', () {
    test('401 直接给出可照做的中文，不包一层「未知错误」', () async {
      final controller = CandidateSearchController(
        service: MiaoaContentService(
            run: (_, _) async => ProcessResult(1, 1, '', 'HTTP 401 unauthorized')),
        probe: CandidateProbe(run: (_, _) async => _ok(_probeStdout)),
      );
      await controller.searchByDescription('喷雾');
      expect(controller.status, CandidateSearchStatus.failed);
      expect(controller.failureMessage, '素材库登录已失效，请在终端执行 miaoa auth login 后重试');
      expect(controller.entries, isEmpty);
    });

    test('未选标签就检索：服务层的中文提示照样透出，不崩', () async {
      final controller = CandidateSearchController(
        service: MiaoaContentService(run: (_, _) async => _ok(_searchJson(1))),
        probe: CandidateProbe(run: (_, _) async => _ok(_probeStdout)),
      );
      await controller.searchByTags(tagIds: const []);
      expect(controller.status, CandidateSearchStatus.failed);
      expect(controller.failureMessage, contains('未选择任何标签'));
    });

    test('重试成功后失败提示要清掉', () async {
      var fail = true;
      final controller = CandidateSearchController(
        service: MiaoaContentService(run: (_, _) async =>
            fail ? ProcessResult(1, 1, '', 'timeout') : _ok(_searchJson(1))),
        probe: CandidateProbe(run: (_, _) async => _ok(_probeStdout)),
      );
      await controller.searchByDescription('喷雾');
      expect(controller.failureMessage, isNotNull);
      fail = false;
      await controller.searchByDescription('喷雾');
      expect(controller.failureMessage, isNull);
      expect(controller.status, CandidateSearchStatus.ready);
    });
  });

  group('竞态：用户手快切换检索方式', () {
    test('过期的检索结果不覆盖新的（否则界面会闪回上一次的候选）', () async {
      final firstGate = Completer<void>();
      var call = 0;
      final controller = CandidateSearchController(
        service: MiaoaContentService(run: (_, args) async {
          if (call++ == 0) {
            await firstGate.future;
            return _ok(_searchJson(2, total: 2));
          }
          return _ok(_searchJson(5, total: 5));
        }),
        probe: CandidateProbe(run: (_, _) async => _ok(_probeStdout)),
      );

      final stale = controller.searchByDescription('旧的');
      final fresh = controller.searchByImage('oss/key.jpg');
      await fresh;
      expect(controller.total, 5);

      firstGate.complete();
      await stale;
      expect(controller.total, 5, reason: '慢到的旧结果必须被丢弃');
      expect(controller.entries, hasLength(5));
    });

    test('过期检索的规格探测也不写进新结果', () async {
      final probeGate = Completer<void>();
      var searchCall = 0;
      var probeCall = 0;
      final controller = CandidateSearchController(
        service: MiaoaContentService(run: (_, _) async =>
            _ok(_searchJson(searchCall++ == 0 ? 1 : 1))),
        probe: CandidateProbe(run: (_, _) async {
          if (probeCall++ == 0) await probeGate.future;
          return _ok(_probeStdout);
        }),
      );

      final stale = controller.searchByDescription('旧的');
      await Future<void>.delayed(Duration.zero);
      final fresh = controller.searchByDescription('新的');
      await fresh;
      probeGate.complete();
      await stale;
      expect(controller.entries, hasLength(1));
    });
  });

  test('dispose 后到达的结果不再 notify（避免对已销毁的控制器发通知）', () async {
    final gate = Completer<void>();
    final controller = CandidateSearchController(
      service: MiaoaContentService(run: (_, _) async {
        await gate.future;
        return _ok(_searchJson(1));
      }),
      probe: CandidateProbe(run: (_, _) async => _ok(_probeStdout)),
    );
    final pending = controller.searchByDescription('喷雾');
    controller.dispose();
    gate.complete();
    await expectLater(pending, completes);
  });

  group('项目组是排他性的筛选条件', () {
    /// 三种检索方式 + 翻页，都必须把 --projects 带上。
    /// 少带一处，用户就会在这个项目里看到别的项目的素材，
    /// 而界面上根本看不出是哪一步漏了。
    Future<List<List<String>>> callsOf(
        Future<void> Function(CandidateSearchController c) run) async {
      final calls = <List<String>>[];
      final controller = CandidateSearchController(
        service: MiaoaContentService(run: (_, args) async {
          calls.add(args);
          return _ok(_searchJson(1, total: 100));
        }),
        probe: CandidateProbe(run: (_, _) async => _ok(_probeStdout)),
        projectIds: const [104],
      );
      await run(controller);
      controller.dispose();
      return calls;
    }

    test('按标签检索带上项目组', () async {
      final calls = await callsOf((c) => c.searchByTags(tagIds: const [13589]));
      expect(calls.single, containsAllInOrder(['--projects', '104']));
    });

    test('按画面描述检索带上项目组', () async {
      final calls = await callsOf((c) => c.searchByDescription('电饭煲'));
      expect(calls.single, containsAllInOrder(['--projects', '104']));
    });

    test('首帧搜图带上项目组', () async {
      final calls = await callsOf((c) => c.searchByImage('oss/a.jpg'));
      expect(calls.single, containsAllInOrder(['--projects', '104']));
    });

    test('翻页时同样带上——翻到第二页就搜遍全库的话更难发现', () async {
      final calls = await callsOf((c) async {
        await c.searchByDescription('电饭煲');
        await c.nextPage();
      });
      expect(calls, hasLength(2));
      expect(calls.last, containsAllInOrder(['--projects', '104']));
    });
  });
}
