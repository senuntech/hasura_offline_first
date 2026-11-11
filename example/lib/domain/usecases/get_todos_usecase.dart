import '../entities/todo_entity.dart';
import '../repositories/todo_repository.dart';

class GetTodosUseCase {
  final ITodoRepository repository;

  const GetTodosUseCase(this.repository);

  Future<List<TodoEntity>> call() async {
    return await repository.getTodos();
  }
}
