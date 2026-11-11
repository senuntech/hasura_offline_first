import '../repositories/todo_repository.dart';

class DeleteTodoUseCase {
  final ITodoRepository repository;

  const DeleteTodoUseCase(this.repository);

  Future<void> call(String id) async {
    return await repository.deleteTodo(id);
  }
}

