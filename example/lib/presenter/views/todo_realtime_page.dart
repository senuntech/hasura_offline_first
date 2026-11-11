import 'dart:async';
import 'package:flutter/material.dart';
import 'package:hasura_offline_first/hasura_offline_first.dart';
import 'package:provider/provider.dart';

import '../../data/models/todo_model.dart';
import '../../domain/entities/todo_entity.dart';
import '../controllers/todo_controller.dart';
import 'components/connectivity_banner.dart';
import 'components/sync_status_badge.dart';
import 'components/todo_tile.dart';

class TodoRealtimePage extends StatefulWidget {
  const TodoRealtimePage({super.key});

  @override
  State<TodoRealtimePage> createState() => _TodoRealtimePageState();
}

class _TodoRealtimePageState extends State<TodoRealtimePage> {
  Snapshot? _snapshot;
  StreamSubscription? _subscription;
  List<TodoEntity> _todos = [];
  bool _isLoading = true;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _startSubscription();
    });
  }

  Future<void> _startSubscription() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final client = context.read<HasuraOfflineFirst>();

      const doc = '''
        subscription WatchTodos {
          teste_offilne(order_by: {id: asc}) {
            id
            task
            check
          }
        }
      ''';

      _snapshot = await client.subscription(doc, key: 'teste_offilne');

      _subscription = _snapshot!.stream.listen(
        (data) {
          if (!mounted) return;
          try {
            List<dynamic> listData = [];
            if (data is List) {
              listData = data;
            } else if (data is Map && data.containsKey('teste_offilne')) {
              listData = data['teste_offilne'] as List;
            } else if (data is Map && data.containsKey('data')) {
              final inner = data['data'];
              if (inner is Map && inner.containsKey('teste_offilne')) {
                listData = inner['teste_offilne'] as List;
              }
            }

            final parsed = listData
                .map((item) =>
                    TodoModel.fromMap(Map<String, dynamic>.from(item as Map)))
                .toList();

            setState(() {
              _todos = parsed;
              _isLoading = false;
              _errorMessage = null;
            });
          } catch (e) {
            setState(() {
              _errorMessage = 'Erro ao processar dados realtime: $e';
              _isLoading = false;
            });
          }
        },
        onError: (err) {
          if (!mounted) return;
          setState(() {
            _errorMessage = 'Erro na subscription WebSocket: $err';
            _isLoading = false;
          });
        },
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = 'Falha ao iniciar subscription: $e';
        _isLoading = false;
      });
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _snapshot?.close();
    super.dispose();
  }

  void _showAddTodoDialog() {
    final textController = TextEditingController();

    showDialog(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Nova Tarefa (Realtime)'),
          content: TextField(
            controller: textController,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Descrição da tarefa',
              hintText: 'Ex: Testar realtime...',
              border: OutlineInputBorder(),
            ),
            onSubmitted: (value) {
              final trimmed = value.trim();
              if (trimmed.isNotEmpty) {
                context.read<TodoController>().addTodo(trimmed);
                Navigator.of(dialogContext).pop();
              }
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancelar'),
            ),
            ElevatedButton(
              onPressed: () {
                final value = textController.text.trim();
                if (value.isNotEmpty) {
                  context.read<TodoController>().addTodo(value);
                  Navigator.of(dialogContext).pop();
                }
              },
              child: const Text('Salvar'),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final todoController = context.read<TodoController>();

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '[SUBSCRIPTION] Tarefas Realtime',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: const BoxDecoration(
                    color: Colors.greenAccent,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 6),
                const Text(
                  'WebSocket Live Stream',
                  style: TextStyle(fontSize: 11, color: Colors.white70),
                ),
              ],
            ),
          ],
        ),
        backgroundColor: Colors.indigo.shade800,
        foregroundColor: Colors.white,
        elevation: 0,
        actions: [
          const SyncStatusBadge(),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () {
              _subscription?.cancel();
              _snapshot?.close();
              _startSubscription();
            },
            tooltip: 'Reconectar Subscription',
          ),
        ],
      ),
      body: Column(
        children: [
          const ConnectivityBanner(),
          if (_errorMessage != null)
            Container(
              width: double.infinity,
              color: Colors.amber.shade100,
              padding: const EdgeInsets.all(8),
              child: Text(
                _errorMessage!,
                style: TextStyle(color: Colors.amber.shade900, fontSize: 13),
                textAlign: TextAlign.center,
              ),
            ),
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _todos.isEmpty
                    ? ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        children: const [
                          SizedBox(height: 100),
                          Icon(Icons.bolt, size: 70, color: Colors.indigo),
                          SizedBox(height: 16),
                          Center(
                            child: Text(
                              'Nenhuma tarefa recebida via WebSocket.\nCrie uma tarefa para ver a atualização realtime!',
                              textAlign: TextAlign.center,
                              style:
                                  TextStyle(color: Colors.grey, fontSize: 16),
                            ),
                          ),
                        ],
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        itemCount: _todos.length,
                        itemBuilder: (context, index) {
                          final todo = _todos[index];
                          return TodoTile(
                            todo: todo,
                            onToggle: (_) => todoController.toggleTodo(todo),
                            onDelete: () =>
                                todoController.deleteTodo(todo.id),
                          );
                        },
                      ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _showAddTodoDialog,
        backgroundColor: Colors.indigo.shade700,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add),
        label: const Text('Nova Tarefa (Live)'),
      ),
    );
  }
}
