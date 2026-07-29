import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:ishkafel/core/models/renew_task.dart';
import 'package:ishkafel/core/storage/file_task_repository.dart';

RenewTask makeTask(String id, DateTime updatedAt) => RenewTask(
      id: id, name: '任务$id', sourcePath: '/v/$id.mp4',
      status: RenewTaskStatus.analyzing,
      createdAt: DateTime.utc(2026, 7, 29), updatedAt: updatedAt,
    );

void main() {
  late Directory tempDir;
  late FileTaskRepository repo;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('ishkafel_test_');
    repo = FileTaskRepository(tempDir);
  });

  tearDown(() async => tempDir.delete(recursive: true));

  test('save 后 findById 取回相同任务', () async {
    final task = makeTask('a', DateTime.utc(2026, 7, 29, 10));
    await repo.save(task);
    expect(await repo.findById('a'), task);
  });

  test('findById 不存在返回 null', () async {
    expect(await repo.findById('nope'), isNull);
  });

  test('findAll 按 updatedAt 倒序', () async {
    await repo.save(makeTask('old', DateTime.utc(2026, 7, 28)));
    await repo.save(makeTask('new', DateTime.utc(2026, 7, 30)));
    final all = await repo.findAll();
    expect(all.map((t) => t.id).toList(), ['new', 'old']);
  });

  test('save 同 id 为覆盖更新', () async {
    final t = makeTask('a', DateTime.utc(2026, 7, 29));
    await repo.save(t);
    await repo.save(t.copyWith(name: '改名'));
    expect((await repo.findById('a'))!.name, '改名');
    expect((await repo.findAll()).length, 1);
  });

  test('delete 后不可见且不抛错', () async {
    await repo.save(makeTask('a', DateTime.utc(2026, 7, 29)));
    await repo.delete('a');
    await repo.delete('a'); // 幂等
    expect(await repo.findById('a'), isNull);
  });

  test('损坏的 JSON 文件被跳过而非炸掉 findAll', () async {
    await repo.save(makeTask('good', DateTime.utc(2026, 7, 29)));
    final bad = File('${tempDir.path}/tasks/bad.json');
    await bad.writeAsString('{not valid');
    final all = await repo.findAll();
    expect(all.map((t) => t.id).toList(), ['good']);
  });

  test('语法合法但字段类型错误的 JSON 被 findAll 跳过', () async {
    await repo.save(makeTask('good', DateTime.utc(2026, 7, 29)));
    final badType = File('${tempDir.path}/tasks/badtype.json');
    // id 是数字，不是字符串 → RenewTask.fromJson 会抛 TypeError
    await badType.writeAsString('{"id": 123, "name": "test", "sourcePath": "/v/test.mp4", "status": "analyzing", "createdAt": "2026-07-29T00:00:00.000Z", "updatedAt": "2026-07-29T00:00:00.000Z"}');
    final all = await repo.findAll();
    expect(all.map((t) => t.id).toList(), ['good']);
  });

  test('字段类型错误的 JSON 文件 findById 返回 null', () async {
    final tasksDir = Directory('${tempDir.path}/tasks');
    await tasksDir.create(recursive: true);
    final badType = File('${tempDir.path}/tasks/badtype.json');
    await badType.writeAsString('{"id": 123, "name": "test", "sourcePath": "/v/test.mp4", "status": "analyzing", "createdAt": "2026-07-29T00:00:00.000Z", "updatedAt": "2026-07-29T00:00:00.000Z"}');
    expect(await repo.findById('badtype'), isNull);
  });

  test('status 为未知枚举名的 JSON 被 findAll 跳过', () async {
    await repo.save(makeTask('good', DateTime.utc(2026, 7, 29)));
    final bad = File('${tempDir.path}/tasks/bad_enum.json');
    await bad.create(recursive: true);
    await bad.writeAsString(
        '{"id":"bad_enum","name":"n","sourcePath":"/x.mp4","status":"notAStatus",'
        '"createdAt":"2026-01-01T00:00:00.000Z","updatedAt":"2026-01-01T00:00:00.000Z"}');
    final all = await repo.findAll();
    expect(all.map((t) => t.id).toList(), ['good']);
  });

  test('status 为未知枚举名的文件 findById 返回 null', () async {
    final bad = File('${tempDir.path}/tasks/x.json');
    await bad.create(recursive: true);
    await bad.writeAsString(
        '{"id":"x","name":"n","sourcePath":"/x.mp4","status":"notAStatus",'
        '"createdAt":"2026-01-01T00:00:00.000Z","updatedAt":"2026-01-01T00:00:00.000Z"}');
    expect(await repo.findById('x'), isNull);
  });
}
