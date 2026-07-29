import '../models/renew_task.dart';

/// 任务存储接口（Repository 模式，便于替换实现与测试 mock）
abstract class TaskRepository {
  Future<List<RenewTask>> findAll();
  Future<RenewTask?> findById(String id);
  Future<void> save(RenewTask task);
  Future<void> delete(String id);
}
