import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/editing/edit_consequence.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';
import 'package:ishkafel/core/replacement/replacement_plan.dart';

/// 两个单元，各两个镜头，都已打好标签
List<SemanticUnit> _units() => const [
      SemanticUnit(
        index: 0,
        startMs: 0,
        endMs: 10000,
        transcript: '第一句台词',
        tags: ['促销'],
        shots: [
          Shot(startMs: 0, endMs: 5000, tags: ['近景']),
          Shot(startMs: 5000, endMs: 10000, tags: ['中景']),
        ],
      ),
      SemanticUnit(
        index: 1,
        startMs: 10000,
        endMs: 20000,
        transcript: '第二句台词',
        tags: ['卖点'],
        shots: [
          Shot(startMs: 10000, endMs: 15000, tags: ['远景']),
          Shot(startMs: 15000, endMs: 20000, tags: ['特写']),
        ],
      ),
    ];

/// 把第 [i] 个单元的结束边界移动 [deltaMs]（同时移动下一个单元的开始，保持无缝）
List<SemanticUnit> _moveBoundary(List<SemanticUnit> units, int i, int deltaMs) {
  final next = [...units];
  final a = next[i];
  next[i] = a.copyWith(
    endMs: a.endMs + deltaMs,
    shots: [
      ...a.shots.sublist(0, a.shots.length - 1),
      a.shots.last.copyWith(endMs: a.shots.last.endMs + deltaMs),
    ],
  );
  if (i + 1 < next.length) {
    final b = next[i + 1];
    next[i + 1] = b.copyWith(
      startMs: b.startMs + deltaMs,
      shots: [
        b.shots.first.copyWith(startMs: b.shots.first.startMs + deltaMs),
        ...b.shots.sublist(1),
      ],
    );
  }
  return next;
}

/// 两个单元都设了整体替换、各选了候选
List<UnitReplacement> _picked() => [
      UnitReplacement.whole(const [101, 102]),
      UnitReplacement.whole(const [201]),
    ];

void main() {
  group('哪些单元受影响', () {
    test('没改就没有后果，不弹任何框', () {
      final ask = EditConsequence.evaluate(
        before: _units(),
        after: _units(),
        replacements: _picked(),
      );

      expect(ask, isNull);
    });

    test('只动了 U1 的边界，就只问 U1', () {
      final after = _moveBoundary(_units(), 0, 2000);

      final ask = EditConsequence.evaluate(
        before: _units(),
        after: after,
        replacements: _picked(),
      );

      expect(ask, isNotNull);
      expect(ask!.unitIndexes, [0, 1],
          reason: '移动 U1 的结束边界同时改了 U2 的开始——两个单元的画面'
              '都变了，只问一个等于漏问');
    });

    test('改的那个单元既没选素材也没打标，就不用问', () {
      final after = _moveBoundary(_units(), 0, 2000);
      final noTags = [
        for (final u in after) u.copyWith(tags: const [], shots: [
          for (final s in u.shots) s.copyWith(tags: const []),
        ]),
      ];

      final ask = EditConsequence.evaluate(
        before: [
          for (final u in _units())
            u.copyWith(tags: const [], shots: [
              for (final s in u.shots) s.copyWith(tags: const []),
            ]),
        ],
        after: noTags,
        replacements: const [],
      );

      expect(ask, isNull,
          reason: '没有已选素材、也没有标签，问「要不要清除/重打」是在问'
              '一个不存在的东西');
    });
  });

  group('默认勾选跟着改动幅度走', () {
    test('只挪了一帧：两项都默认不勾', () {
      final after = _moveBoundary(_units(), 0, 33);

      final ask = EditConsequence.evaluate(
        before: _units(),
        after: after,
        replacements: _picked(),
      );

      expect(ask!.clearCandidatesByDefault, isFalse);
      expect(ask.retagByDefault, isFalse,
          reason: '只改了一点点，通常不影响打标结果和挑好的素材——'
              '默认勾上会让用户白白重挑一遍');
    });

    test('挪了三成时长：两项都默认勾上', () {
      final after = _moveBoundary(_units(), 0, 3000);

      final ask = EditConsequence.evaluate(
        before: _units(),
        after: after,
        replacements: _picked(),
      );

      expect(ask!.clearCandidatesByDefault, isTrue);
      expect(ask.retagByDefault, isTrue);
    });

    test('单元数变了（拆分/合并）一律按大改动处理', () {
      final after = [
        ..._units(),
        const SemanticUnit(
          index: 2,
          startMs: 20000,
          endMs: 25000,
          transcript: '拆出来的',
          shots: [Shot(startMs: 20000, endMs: 25000)],
        ),
      ];

      final ask = EditConsequence.evaluate(
        before: _units(),
        after: after,
        replacements: _picked(),
      );

      expect(ask!.structural, isTrue);
      expect(ask.clearCandidatesByDefault, isTrue);
      expect(ask.retagByDefault, isTrue);
    });
  });

  group('应用用户的选择', () {
    test('选择清除素材：只清受影响那几个单元，别人的不动', () {
      final after = _moveBoundary(_units(), 0, 3000);
      final ask = EditConsequence.evaluate(
        before: _units(),
        after: after,
        replacements: _picked(),
      )!;

      final cleared = ask.clearCandidates(_picked());

      expect(cleared[0].mode, ReplacementMode.keepOriginal);
      expect(cleared[1].mode, ReplacementMode.keepOriginal);
    });

    test('第三个单元没被碰过，它挑好的素材必须原样保留', () {
      final before = [
        ..._units(),
        const SemanticUnit(
          index: 2,
          startMs: 20000,
          endMs: 30000,
          transcript: '第三句',
          shots: [Shot(startMs: 20000, endMs: 30000, tags: ['全景'])],
        ),
      ];
      final after = _moveBoundary(before, 0, 3000);
      final plan = [..._picked(), UnitReplacement.whole(const [301])];

      final ask = EditConsequence.evaluate(
        before: before,
        after: after,
        replacements: plan,
      )!;
      final cleared = ask.clearCandidates(plan);

      expect(cleared[2].wholeCandidateIds, [301],
          reason: '改谁清谁——顺手把没碰过的单元一起清了，用户会以为软件坏了');
    });

    test('选择重新打标：把受影响单元的标签标记为过期，不是直接抹掉', () {
      final after = _moveBoundary(_units(), 0, 3000);
      final ask = EditConsequence.evaluate(
        before: _units(),
        after: after,
        replacements: _picked(),
      )!;

      final marked = ask.markForRetag(after);

      expect(marked[0].shots.every((s) => s.tagsStale), isTrue);
      expect(marked[0].shots.first.tags, ['近景'],
          reason: '重打是异步的，这中间把标签抹成空的，用户会以为标签丢了');
    });
  });

  group('合并：标签用合并目标的', () {
    test('A 合并到 B 后，合并出来的那个单元保留 B 的标签', () {
      final merged = EditConsequence.mergeTags(
        target: _units()[1],
        absorbed: _units()[0],
      );

      expect(merged.tags, ['卖点'],
          reason: '产品决策：A 合并到 B，标签就直接用 B 的');
    });
  });
}
