import 'dart:async';
import 'package:flutter/material.dart';
import 'package:hasura_offline_first/hasura_offline_first.dart';
import 'package:uuid/uuid.dart';

import '../../domain/entities/todo_entity.dart';
import '../../domain/usecases/add_todo_usecase.dart';
import '../../domain/usecases/delete_todo_usecase.dart';
import '../../domain/usecases/get_todos_usecase.dart';
import '../../domain/usecases/toggle_todo_usecase.dart';

enum TodoViewState { initial, loading, success, error }

/// Presentation controller managing Todo list state, optimistic UI updates, and error handling.
class TodoController extends ChangeNotifier {
  final GetTodosUseCase getTodosUseCase;
  final AddTodoUseCase addTodoUseCase;
  final ToggleTodoUseCase toggleTodoUseCase;
  final DeleteTodoUseCase deleteTodoUseCase;
  final HasuraOfflineFirst client;

  List<TodoEntity> _todos = [];
  TodoViewState _state = TodoViewState.initial;
  String? _errorMessage;
  final _uuid = const Uuid();

  StreamSubscription? _tableSub;
  StreamSubscription? _conflictSub;

  TodoController({
    required this.getTodosUseCase,
    required this.addTodoUseCase,
    required this.toggleTodoUseCase,
    required this.deleteTodoUseCase,
    required this.client,
  }) {
    // Listen to local SQLite table changes (local writes or pull delta sync)
    _tableSub = client.onTableChanged.listen((event) {
      if (event.tableName == 'teste_offilne') {
        fetchTodos(showLoading: false);
      }
    });

    // Listen to Server Authority conflict purges (when another user deleted the record on server)
    _conflictSub = client.onConflictPurge.listen((event) {
      if (event.tableName == 'teste_offilne') {
        _errorMessage =
            'Item excluído remotamente por outro usuário no servidor.';
        fetchTodos(showLoading: false);
      }
    });
  }

  @override
  void dispose() {
    _tableSub?.cancel();
    _conflictSub?.cancel();
    super.dispose();
  }

  List<TodoEntity> get todos => List.unmodifiable(_todos);
  TodoViewState get state => _state;
  bool get isLoading => _state == TodoViewState.loading;
  String? get errorMessage => _errorMessage;

  Future<void> fetchTodos({bool showLoading = true}) async {
    if (showLoading) {
      _state = TodoViewState.loading;
      _errorMessage = null;
      notifyListeners();
    }

    try {
      _todos = await getTodosUseCase();
      _state = TodoViewState.success;
    } on HasuraCacheMissException {
      _errorMessage = 'Sem conexão e sem dados no cache local.';
      _state = TodoViewState.error;
    } catch (e) {
      _errorMessage = 'Erro ao carregar tarefas: $e';
      _state = TodoViewState.error;
    } finally {
      notifyListeners();
    }
  }

  Future<void> addTodo(String title) async {
    final trimmed = title.trim();
    if (trimmed.isEmpty) return;

    final newTodo = TodoEntity(
      id: _uuid.v4(),
      task: trimmed,
      check: false,
    );

    // Optimistic UI update
    _todos = [..._todos, newTodo];
    notifyListeners();

    try {
      await addTodoUseCase(newTodo);
    } catch (e) {
      // Revert if severe error
      _errorMessage = 'Erro ao adicionar tarefa: $e';
      notifyListeners();
    }
  }

  Future<void> toggleTodo(TodoEntity todo) async {
    final updated = todo.copyWith(check: !todo.check);

    // Optimistic UI update
    _todos = _todos.map((t) => t.id == todo.id ? updated : t).toList();
    notifyListeners();

    try {
      await toggleTodoUseCase(id: todo.id, currentCheck: todo.check);
    } catch (e) {
      _errorMessage = 'Erro ao alterar status: $e';
      notifyListeners();
    }
  }

  Future<void> deleteTodo(String id) async {
    final previous = _todos;

    // Optimistic UI update
    _todos = _todos.where((t) => t.id != id).toList();
    notifyListeners();

    try {
      await deleteTodoUseCase(id);
    } catch (e) {
      _todos = previous;
      _errorMessage = 'Erro ao excluir tarefa: $e';
      notifyListeners();
    }
  }
}
