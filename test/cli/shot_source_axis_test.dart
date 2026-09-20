import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/cli/task_view.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/models/semantic_unit.dart';
import 'package:ishkafel/core/models/shot.dart';

/// `sourceStartMs` / `sourceEndMs` 有**两种含义**：没固定底片时是原片毫秒，
/// 固定过底片时是**素材内偏移**。人在界面上看不到这个区别（界面显示的是
/// 成片时间），而 Agent 拿到的是裸 JSON——它照着这两个数去原片抽帧，
/// 抽到的是一段毫不相干的画面，**而且不会报错**。
///
/// 所以必须明说这两个数量的是哪个文件。
void main() {
  RenewTask taskWith({int? baseCandidateId}) => RenewTask(
        id: 't1',
        name: '测试',
        status: RenewTaskStatus.ready,
        createdAt: DateTime(2026, 9, 20),
        updatedAt: DateTime(2026, 9, 20),
        units: [
          SemanticUnit(
            uid: 'u0',
            index: 0,
            startMs: 1000,
            endMs: 3000,
            transcript: '一句话',
            baseCandidateId: baseCandidateId,
            shots: const [Shot(startMs: 1000, endMs: 2000)],
          ),
        ],
      );

  Map<String, dynamic> firstShot(RenewTask t) =>
      ((taskToJson(t)['units'] as List).first
          as Map<String, dynamic>)['shots'][0] as Map<String, dynamic>;

  test('没固定底片：这两个数量的是原片', () {
    expect(firstShot(taskWith())['sourceOf'], 'original');
  });

  test('固定过底片：量的是那条素材，而且要说清是哪一条', () {
    final shot = firstShot(taskWith(baseCandidateId: 77));
    expect(shot['sourceOf'], 'material',
        reason: '照原片去对会对到一段毫不相干的画面，这里必须说清换了参照物');
    expect(shot['sourceMaterialId'], 77,
        reason: '只说「是素材」不够——得能问出是哪一条，否则还是抽不了帧');
  });

  test('没固定底片时不报 sourceMaterialId——空值和「有一条素材」要分得开', () {
    expect(firstShot(taskWith()).containsKey('sourceMaterialId'), isFalse);
  });
}
