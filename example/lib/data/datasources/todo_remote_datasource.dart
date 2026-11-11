import 'package:hasura_offline_first/hasura_offline_first.dart';
import '../models/todo_model.dart';

abstract class ITodoRemoteDataSource {
  Future<List<TodoModel>> getTodos();
  Future<void> addTodo(TodoModel todo);
  Future<void> toggleTodo({required String id, required bool check});
  Future<void> deleteTodo(String id);
}

class TodoRemoteDataSource implements ITodoRemoteDataSource {
  final IHasuraConnect client;

  TodoRemoteDataSource(this.client);

  static const String _getTodosQuery = '''
    query GetTodos {
      teste_offilne(order_by: {task: asc}) {
        id
        task
        check
      }
    }
  ''';

  static const String _addTodoMutation = '''
    mutation AddTodo(\$id: uuid!, \$task: String!, \$check: Boolean!) {
      insert_teste_offilne_one(object: {id: \$id, task: \$task, check: \$check}) {
        id
        task
        check
      }
    }
  ''';

  static const String _toggleTodoMutation = '''
    mutation ToggleTodo(\$id: uuid!, \$check: Boolean!) {
      update_teste_offilne_by_pk(pk_columns: {id: \$id}, _set: {check: \$check}) {
        id
        task
        check
      }
    }
  ''';

  static const String _deleteTodoMutation = '''
    mutation DeleteTodo(\$id: uuid!) {
      delete_teste_offilne_by_pk(id: \$id) {
        id
      }
    }
  ''';

  @override
  Future<List<TodoModel>> getTodos() async {
    final response = await client.query(_getTodosQuery, key: 'teste_offilne');

    if (response is List) {
      return response
          .map((item) =>
              TodoModel.fromMap(Map<String, dynamic>.from(item as Map)))
          .toList();
    } else if (response is Map<String, dynamic> &&
        response.containsKey('teste_offilne')) {
      final list = response['teste_offilne'] as List;
      return list
          .map((item) =>
              TodoModel.fromMap(Map<String, dynamic>.from(item as Map)))
          .toList();
    }

    return [];
  }

  @override
  Future<void> addTodo(TodoModel todo) async {
    await client.mutation(
      _addTodoMutation,
      variables: {
        'id': todo.id,
        'task': todo.task,
        'check': todo.check,
      },
    );
  }

  @override
  Future<void> toggleTodo({required String id, required bool check}) async {
    await client.mutation(
      _toggleTodoMutation,
      variables: {
        'id': id,
        'check': check,
      },
    );
  }

  @override
  Future<void> deleteTodo(String id) async {
    await client.mutation(
      _deleteTodoMutation,
      variables: {
        'id': id,
      },
    );
  }
}
