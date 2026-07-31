import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/features/workbench/timeline/text_layout_cache.dart';

void main() {
  group('文字排版缓存', () {
    test('同样的文字与排版参数复用同一个 TextPainter', () {
      final cache = TextLayoutCache();
      addTearDown(cache.clear);

      final a = cache.acquire(
          text: '00:15', color: const Color(0xFFFFFFFF), fontSize: 10);
      final b = cache.acquire(
          text: '00:15', color: const Color(0xFFFFFFFF), fontSize: 10);

      expect(identical(a, b), isTrue,
          reason: '刻度标签只有有限几种，每帧重新 layout 是纯浪费');
      expect(cache.length, 1);
    });

    test('maxWidth 不同视为不同条目（省略结果不同，混用会画错）', () {
      final cache = TextLayoutCache();
      addTearDown(cache.clear);

      final wide = cache.acquire(
          text: '很长的一段台词内容',
          color: const Color(0xFFFFFFFF),
          fontSize: 12,
          maxWidth: 200);
      final narrow = cache.acquire(
          text: '很长的一段台词内容',
          color: const Color(0xFFFFFFFF),
          fontSize: 12,
          maxWidth: 30);

      expect(identical(wide, narrow), isFalse);
      expect(wide.width, greaterThan(narrow.width));
    });

    test('颜色与字号也参与键，不会串用', () {
      final cache = TextLayoutCache();
      addTearDown(cache.clear);

      cache.acquire(text: 'U1', color: const Color(0xFFFFFFFF), fontSize: 12);
      cache.acquire(text: 'U1', color: const Color(0xFF888888), fontSize: 12);
      cache.acquire(text: 'U1', color: const Color(0xFFFFFFFF), fontSize: 10);

      expect(cache.length, 3);
    });

    test('超出容量按最久未使用淘汰', () {
      final cache = TextLayoutCache(capacity: 2);
      addTearDown(cache.clear);

      final first =
          cache.acquire(text: 'a', color: const Color(0xFFFFFFFF), fontSize: 10);
      cache.acquire(text: 'b', color: const Color(0xFFFFFFFF), fontSize: 10);
      // 再次使用 a，让 b 成为最久未使用
      cache.acquire(text: 'a', color: const Color(0xFFFFFFFF), fontSize: 10);
      cache.acquire(text: 'c', color: const Color(0xFFFFFFFF), fontSize: 10);

      expect(cache.length, 2, reason: '无上限的缓存在长素材上会一直涨');
      final againA =
          cache.acquire(text: 'a', color: const Color(0xFFFFFFFF), fontSize: 10);
      expect(identical(againA, first), isTrue, reason: 'a 最近用过，不该被淘汰');
    });

    test('负数 maxWidth 不抛异常（绘制中途抛异常会丢掉整帧后续绘制）', () {
      final cache = TextLayoutCache();
      addTearDown(cache.clear);

      expect(
        () => cache.acquire(
            text: 'U1',
            color: const Color(0xFFFFFFFF),
            fontSize: 12,
            maxWidth: -8),
        returnsNormally,
      );
    });
  });
}
