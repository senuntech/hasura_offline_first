// ignore_for_file: avoid_relative_lib_imports
import 'package:flutter_test/flutter_test.dart';
import '../example/lib/data/datasources/todo_remote_datasource.dart';
import '../example/lib/data/models/todo_model.dart';
import '../example/lib/data/repositories/todo_repository_impl.dart';
import '../example/lib/domain/usecases/add_todo_usecase.dart';
import '../example/lib/domain/usecases/delete_todo_usecase.dart';
import '../example/lib/domain/usecases/get_todos_usecase.dart';
import '../example/lib/domain/usecases/toggle_todo_usecase.dart';
import '../example/lib/presenter/controllers/todo_controller.dart';
import 'package:hasura_offline_first/hasura_offline_first.dart';

import 'mocks/fake_connectivity.dart';

class FakeTodoRemoteDataSource implements ITodoRemoteDataSource {
  final List<TodoModel> memoryStore = [];

  @override
  Future<List<TodoModel>> getTodos() async => [...memoryStore];

  @override
  Future<void> addTodo(TodoModel todo) async {
    memoryStore.add(todo);
  }

  @override
  Future<void> toggleTodo({required String id, required bool check}) async {
    final index = memoryStore.indexWhere((t) => t.id == id);
    if (index != -1) {
      final current = memoryStore[index];
      memoryStore[index] = TodoModel(
        id: current.id,
        task: current.task,
        check: check,
      );
    }
  }

  @override
  Future<void> deleteTodo(String id) async {
    memoryStore.removeWhere((t) => t.id == id);
  }
}

void main() {
  group('Clean Architecture Example Tests', () {
    late FakeTodoRemoteDataSource fakeDataSource;
    late TodoRepositoryImpl repository;
    late GetTodosUseCase getTodosUseCase;
    late AddTodoUseCase addTodoUseCase;
    late ToggleTodoUseCase toggleTodoUseCase;
    late DeleteTodoUseCase deleteTodoUseCase;
    late HasuraOfflineFirst client;
    late FakeConnectivity fakeConnectivity;
    late TodoController controller;

    setUp(() {
      fakeDataSource = FakeTodoRemoteDataSource();
      repository = TodoRepositoryImpl(fakeDataSource);
      getTodosUseCase = GetTodosUseCase(repository);
      addTodoUseCase = AddTodoUseCase(repository);
      toggleTodoUseCase = ToggleTodoUseCase(repository);
      deleteTodoUseCase = DeleteTodoUseCase(repository);

      fakeConnectivity = FakeConnectivity();
      client = HasuraOfflineFirst(
        'https://fake.url',
        networkManager: NetworkManager(connectivity: fakeConnectivity),
        storageDriver: InMemoryStorageDriver(),
      );

      controller = TodoController(
        getTodosUseCase: getTodosUseCase,
        addTodoUseCase: addTodoUseCase,
        toggleTodoUseCase: toggleTodoUseCase,
        deleteTodoUseCase: deleteTodoUseCase,
        client: client,
      );
    });

    tearDown(() {
      client.dispose();
      fakeConnectivity.dispose();
      controller.dispose();
    });

    test('addTodo updates UI optimistically and persists in datasource',
        () async {
      await controller.addTodo('Testar offline-first');

      expect(controller.todos.length, equals(1));
      expect(controller.todos.first.task, equals('Testar offline-first'));
      expect(controller.todos.first.check, isFalse);

      final inStorage = await fakeDataSource.getTodos();
      expect(inStorage.length, equals(1));
    });

    test('toggleTodo updates check state optimistically', () async {
      await controller.addTodo('Comprar pão');
      final todo = controller.todos.first;

      await controller.toggleTodo(todo);

      expect(controller.todos.first.check, isTrue);

      final inStorage = await fakeDataSource.getTodos();
      expect(inStorage.first.check, isTrue);
    });

    test('deleteTodo removes item optimistically', () async {
      await controller.addTodo('Tarefa a ser deletada');
      final todo = controller.todos.first;

      await controller.deleteTodo(todo.id);

      expect(controller.todos, isEmpty);

      final inStorage = await fakeDataSource.getTodos();
      expect(inStorage, isEmpty);
    });

    test('simulateOffline alters connectivity status and enables outbox',
        () async {
      expect(await client.isConnected, isTrue);

      client.simulateOffline(true);
      expect(await client.isConnected, isFalse);
      expect(client.isSimulatingOffline, isTrue);

      client.simulateOffline(false);
      expect(client.isSimulatingOffline, isFalse);
    });
  });
}
