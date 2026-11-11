import '../../domain/entities/todo_entity.dart';

/// Data transfer object extending [TodoEntity] with serialization logic.
class TodoModel extends TodoEntity {
  const TodoModel({
    required super.id,
    required super.task,
    required super.check,
  });

  factory TodoModel.fromMap(Map<String, dynamic> map) {
    return TodoModel(
      id: map['id']?.toString() ?? '',
      task: map['task']?.toString() ?? '',
      check: map['check'] == true || map['check'] == 1,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'task': task,
      'check': check,
    };
  }

  factory TodoModel.fromEntity(TodoEntity entity) {
    return TodoModel(
      id: entity.id,
      task: entity.task,
      check: entity.check,
    );
  }
}
