import 'package:flutter/material.dart';
import 'package:hasura_offline_first/hasura_offline_first.dart';
import 'package:provider/provider.dart';

import 'core/hasura_config.dart';
import 'data/datasources/todo_remote_datasource.dart';
import 'data/repositories/todo_repository_impl.dart';
import 'domain/repositories/todo_repository.dart';
import 'domain/usecases/add_todo_usecase.dart';
import 'domain/usecases/delete_todo_usecase.dart';
import 'domain/usecases/get_todos_usecase.dart';
import 'domain/usecases/toggle_todo_usecase.dart';
import 'presenter/controllers/connectivity_controller.dart';
import 'presenter/controllers/todo_controller.dart';
import 'presenter/views/todo_page.dart';

class AppWidget extends StatelessWidget {
  const AppWidget({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        // 1. Core Hasura Client
        Provider<HasuraOfflineFirst>(
          create: (_) => HasuraConfig.createClient(),
          dispose: (_, client) => client.dispose(),
        ),

        // 2. Data Layer
        ProxyProvider<HasuraOfflineFirst, ITodoRemoteDataSource>(
          update: (_, client, __) => TodoRemoteDataSource(client),
        ),
        ProxyProvider<ITodoRemoteDataSource, ITodoRepository>(
          update: (_, dataSource, __) => TodoRepositoryImpl(dataSource),
        ),

        // 3. Domain UseCases
        ProxyProvider<ITodoRepository, GetTodosUseCase>(
          update: (_, repo, __) => GetTodosUseCase(repo),
        ),
        ProxyProvider<ITodoRepository, AddTodoUseCase>(
          update: (_, repo, __) => AddTodoUseCase(repo),
        ),
        ProxyProvider<ITodoRepository, ToggleTodoUseCase>(
          update: (_, repo, __) => ToggleTodoUseCase(repo),
        ),
        ProxyProvider<ITodoRepository, DeleteTodoUseCase>(
          update: (_, repo, __) => DeleteTodoUseCase(repo),
        ),

        // 4. Presenter Controllers (ChangeNotifier)
        ChangeNotifierProxyProvider<HasuraOfflineFirst, ConnectivityController>(
          create: (ctx) =>
              ConnectivityController(ctx.read<HasuraOfflineFirst>()),
          update: (_, client, controller) =>
              controller ?? ConnectivityController(client),
        ),
        ChangeNotifierProxyProvider4<GetTodosUseCase, AddTodoUseCase,
            ToggleTodoUseCase, DeleteTodoUseCase, TodoController>(
          create: (ctx) => TodoController(
            getTodosUseCase: ctx.read<GetTodosUseCase>(),
            addTodoUseCase: ctx.read<AddTodoUseCase>(),
            toggleTodoUseCase: ctx.read<ToggleTodoUseCase>(),
            deleteTodoUseCase: ctx.read<DeleteTodoUseCase>(),
            client: ctx.read<HasuraOfflineFirst>(),
          ),
          update: (context, getTodos, addTodo, toggleTodo, deleteTodo,
                  controller) =>
              controller ??
              TodoController(
                getTodosUseCase: getTodos,
                addTodoUseCase: addTodo,
                toggleTodoUseCase: toggleTodo,
                deleteTodoUseCase: deleteTodo,
                client: context.read<HasuraOfflineFirst>(),
              ),
        ),
      ],
      child: MaterialApp(
        title: 'Hasura Offline-First Todo (Clean Architecture)',
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
          useMaterial3: true,
        ),
        home: const TodoPage(),
        debugShowCheckedModeBanner: false,
      ),
    );
  }
}
