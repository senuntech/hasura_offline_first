import '../../domain/entities/todo_entity.dart';
import '../../domain/repositories/todo_repository.dart';
import '../datasources/todo_remote_datasource.dart';
import '../models/todo_model.dart';

class TodoRepositoryImpl implements ITodoRepository {
  final ITodoRemoteDataSource remoteDataSource;

  TodoRepositoryImpl(this.remoteDataSource);

  @override
  Future<List<TodoEntity>> getTodos() async {
    return await remoteDataSource.getTodos();
  }

  @override
  Future<void> addTodo(TodoEntity todo) async {
    final model = TodoModel.fromEntity(todo);
    await remoteDataSource.addTodo(model);
  }

  @override
  Future<void> toggleTodo(
      {required String id, required bool currentCheck}) async {
    await remoteDataSource.toggleTodo(id: id, check: !currentCheck);
  }

  @override
  Future<void> deleteTodo(String id) async {
    await remoteDataSource.deleteTodo(id);
  }
}
