import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../controllers/todo_controller.dart';
import 'components/connectivity_banner.dart';
import 'components/sync_status_badge.dart';
import 'components/todo_tile.dart';

class TodoPage extends StatefulWidget {
  const TodoPage({super.key});

  @override
  State<TodoPage> createState() => _TodoPageState();
}

class _TodoPageState extends State<TodoPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<TodoController>().fetchTodos();
    });
  }

  void _showAddTodoDialog() {
    final textController = TextEditingController();

    showDialog(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Nova Tarefa'),
          content: TextField(
            controller: textController,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Descrição da tarefa',
              hintText: 'Ex: Comprar café...',
              border: OutlineInputBorder(),
            ),
            onSubmitted: (value) {
              if (value.trim().isNotEmpty) {
                context.read<TodoController>().addTodo(value);
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
    final controller = context.watch<TodoController>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Tarefas (teste_offilne)'),
        backgroundColor: Colors.teal.shade800,
        foregroundColor: Colors.white,
        elevation: 0,
        actions: [
          const SyncStatusBadge(),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => controller.fetchTodos(),
            tooltip: 'Recarregar dados',
          )
        ],
      ),
      body: Column(
        children: [
          const ConnectivityBanner(),
          if (controller.errorMessage != null)
            Container(
              width: double.infinity,
              color: Colors.red.shade100,
              padding: const EdgeInsets.all(8),
              child: Text(
                controller.errorMessage!,
                style: TextStyle(color: Colors.red.shade900, fontSize: 13),
                textAlign: TextAlign.center,
              ),
            ),
          Expanded(
            child: controller.isLoading
                ? const Center(child: CircularProgressIndicator())
                : RefreshIndicator(
                    onRefresh: () => controller.fetchTodos(),
                    child: controller.todos.isEmpty
                        ? ListView(
                            physics: const AlwaysScrollableScrollPhysics(),
                            children: const [
                              SizedBox(height: 100),
                              Icon(Icons.checklist,
                                  size: 70, color: Colors.grey),
                              SizedBox(height: 16),
                              Center(
                                child: Text(
                                  'Nenhuma tarefa cadastrada.\nClique no botão "+" para adicionar!',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                      color: Colors.grey, fontSize: 16),
                                ),
                              ),
                            ],
                          )
                        : ListView.builder(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            itemCount: controller.todos.length,
                            itemBuilder: (context, index) {
                              final todo = controller.todos[index];
                              return TodoTile(
                                todo: todo,
                                onToggle: (_) => controller.toggleTodo(todo),
                                onDelete: () => controller.deleteTodo(todo.id),
                              );
                            },
                          ),
                  ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _showAddTodoDialog,
        backgroundColor: Colors.teal.shade700,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add),
        label: const Text('Nova Tarefa'),
      ),
    );
  }
}
