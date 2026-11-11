import '../entities/todo_entity.dart';

/// Contract definition for Todo operations.
abstract class ITodoRepository {
  /// Fetches all todos (online retrieves fresh data & caches; offline falls back to local cache).
  Future<List<TodoEntity>> getTodos();

  /// Adds a new todo (online saves directly; offline enqueues into Outbox).
  Future<void> addTodo(TodoEntity todo);

  /// Toggles the completion status of a todo.
  Future<void> toggleTodo({required String id, required bool currentCheck});

  /// Deletes a todo by its ID.
  Future<void> deleteTodo(String id);
}
