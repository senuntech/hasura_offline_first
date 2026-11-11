import '../entities/todo_entity.dart';
import '../repositories/todo_repository.dart';

class AddTodoUseCase {
  final ITodoRepository repository;

  const AddTodoUseCase(this.repository);

  Future<void> call(TodoEntity todo) async {
    return await repository.addTodo(todo);
  }
}

