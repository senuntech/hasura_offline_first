/// Domain entity representing a Todo item in the application.
class TodoEntity {
  final String id;
  final String task;
  final bool check;

  const TodoEntity({
    required this.id,
    required this.task,
    required this.check,
  });

  TodoEntity copyWith({
    String? id,
    String? task,
    bool? check,
  }) {
    return TodoEntity(
      id: id ?? this.id,
      task: task ?? this.task,
      check: check ?? this.check,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TodoEntity &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          task == other.task &&
          check == other.check;

  @override
  int get hashCode => id.hashCode ^ task.hashCode ^ check.hashCode;
}

