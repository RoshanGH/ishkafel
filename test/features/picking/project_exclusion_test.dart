import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/miaoa/miaoa_content_service.dart';
import 'package:ishkafel/features/picking/project_exclusion.dart';

CandidateMaterial _m(int id, int project) => CandidateMaterial(
      id: id,
      name: 'm$id',
      projectId: project,
      sceneDescription: '',
      thumbnailUrl: null,
      previewUrl: 'https://c/$id.mov',
      fileKey: 'k$id',
      tags: const [],
    );

/// 「换成别的项目拍的」是这条线最常见的诉求——翻新的意义就是换掉原来那批画面。
/// 而语义检索越准，搜出来越是原项目自己的素材（跟原镜最像的当然是它）。
/// 真机上验收 Agent 只能靠 name 前缀手工过滤 35 个镜头。
void main() {
  test('排除掉的项目不出现在结果里', () async {
    final page = await searchExcluding(
      fetch: (p) async => CandidatePage(
        items: [_m(1, 107), _m(2, 200), _m(3, 107), _m(4, 201)],
        total: 4,
        skipped: 0,
      ),
      exclude: const {107},
      want: 50,
    );

    expect(page.items.map((e) => e.id), [2, 4]);
    expect(page.excludedCount, 2);
  });

  test('一页被排空就往后翻——不然人拿到的是空列表，还得自己想到翻页', () async {
    var fetched = 0;
    final page = await searchExcluding(
      fetch: (p) async {
        fetched++;
        // 前两页全是原项目的，第三页才有别的
        return CandidatePage(
          items: p <= 2 ? [_m(p * 10, 107)] : [_m(p * 10, 200)],
          total: 90,
          skipped: 0,
        );
      },
      exclude: const {107},
      want: 1,
    );

    expect(page.items.single.projectId, 200);
    expect(fetched, 3);
  });

  test('翻到底也没有就如实返回空，不无限翻', () async {
    var fetched = 0;
    final page = await searchExcluding(
      fetch: (p) async {
        fetched++;
        return CandidatePage(items: [_m(p, 107)], total: 10000, skipped: 0);
      },
      exclude: const {107},
      want: 50,
      maxPages: 4,
    );

    expect(page.items, isEmpty);
    expect(fetched, 4, reason: '翻页是要钱要时间的，不能一直翻下去');
  });

  test('不排除任何项目时原样返回，不白翻页', () async {
    var fetched = 0;
    final page = await searchExcluding(
      fetch: (p) async {
        fetched++;
        return CandidatePage(items: [_m(1, 107)], total: 1, skipped: 0);
      },
      exclude: const {},
      want: 50,
    );

    expect(page.items, hasLength(1));
    expect(fetched, 1);
  });
}
