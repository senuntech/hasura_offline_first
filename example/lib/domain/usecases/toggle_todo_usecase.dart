import '../repositories/todo_repository.dart';

class ToggleTodoUseCase {
  final ITodoRepository repository;

  const ToggleTodoUseCase(this.repository);

  Future<void> call({required String id, required bool currentCheck}) async {
    return await repository.toggleTodo(id: id, currentCheck: currentCheck);
  }
}

