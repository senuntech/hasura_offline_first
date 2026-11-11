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

  // Track pending optimistic mutations to reconcile seamlessly with WebSocket events
  final Map<String, bool> _pendingOptimisticToggles = {};
  final Set<String> _pendingOptimisticDeletes = {};

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

            // Intelligent Optimistic Reconciliation:
            // 1. Preserve optimistic temporary additions not yet reflected on server
            final merged = <TodoEntity>[];
            for (final localItem in _todos) {
              if (localItem.id.startsWith('temp-')) {
                merged.add(localItem);
              }
            }

            // 2. Merge server items with active optimistic pending mutations
            for (final serverTodo in parsed) {
              if (_pendingOptimisticDeletes.contains(serverTodo.id)) {
                continue; // Skip items deleted locally that server hasn't purged yet
              }

              if (_pendingOptimisticToggles.containsKey(serverTodo.id)) {
                // Keep local optimistic toggle state until acknowledged by server
                merged.add(serverTodo.copyWith(
                  check: _pendingOptimisticToggles[serverTodo.id],
                ));
              } else {
                merged.add(serverTodo);
              }
            }

            setState(() {
              _todos = merged;
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

  /// Instant 0ms Optimistic Toggle with background synchronization (Facebook-style)
  void _toggleTodoOptimistic(TodoEntity todo) {
    final nextCheck = !todo.check;

    // 1. Immediate in-memory state update (0ms latency / 60-120 FPS)
    _pendingOptimisticToggles[todo.id] = nextCheck;
    final index = _todos.indexWhere((t) => t.id == todo.id);
    if (index != -1) {
      setState(() {
        _todos[index] = todo.copyWith(check: nextCheck);
      });
    }

    // 2. Non-blocking background persistence & upstream push
    final controller = context.read<TodoController>();
    controller.toggleTodo(todo).then((_) {
      _pendingOptimisticToggles.remove(todo.id);
    }).catchError((err) {
      // Rollback on failure
      _pendingOptimisticToggles.remove(todo.id);
      if (mounted) {
        final rollbackIndex = _todos.indexWhere((t) => t.id == todo.id);
        if (rollbackIndex != -1) {
          setState(() {
            _todos[rollbackIndex] = todo.copyWith(check: todo.check);
          });
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Falha ao atualizar tarefa: $err'),
            backgroundColor: Colors.red,
          ),
        );
      }
    });
  }

  /// Instant 0ms Optimistic Delete with background synchronization
  void _deleteTodoOptimistic(String id) {
    _pendingOptimisticDeletes.add(id);
    final removed = _todos.firstWhere(
      (t) => t.id == id,
      orElse: () => TodoEntity(id: id, task: '', check: false),
    );

    // 1. Immediate visual removal from list
    setState(() {
      _todos.removeWhere((t) => t.id == id);
    });

    // 2. Non-blocking background deletion
    final controller = context.read<TodoController>();
    controller.deleteTodo(id).then((_) {
      _pendingOptimisticDeletes.remove(id);
    }).catchError((err) {
      _pendingOptimisticDeletes.remove(id);
      if (mounted && removed.task.isNotEmpty) {
        setState(() {
          _todos.add(removed);
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Falha ao excluir tarefa: $err'),
            backgroundColor: Colors.red,
          ),
        );
      }
    });
  }

  /// Instant 0ms Optimistic Add with background synchronization
  void _addTodoOptimistic(String task) {
    final tempId = 'temp-${DateTime.now().millisecondsSinceEpoch}';
    final optimisticTodo = TodoEntity(id: tempId, task: task, check: false);

    // 1. Immediate visual insertion at top
    setState(() {
      _todos.insert(0, optimisticTodo);
    });

    // 2. Non-blocking background creation
    final controller = context.read<TodoController>();
    controller.addTodo(task).then((_) {
      // Temporary item will be naturally replaced when WebSocket emits new list
      if (mounted) {
        setState(() {
          _todos.removeWhere((t) => t.id == tempId);
        });
      }
    }).catchError((err) {
      if (mounted) {
        setState(() {
          _todos.removeWhere((t) => t.id == tempId);
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Falha ao adicionar tarefa: $err'),
            backgroundColor: Colors.red,
          ),
        );
      }
    });
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
                _addTodoOptimistic(trimmed);
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
                  _addTodoOptimistic(value);
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
                            onToggle: (_) => _toggleTodoOptimistic(todo),
                            onDelete: () => _deleteTodoOptimistic(todo.id),
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

