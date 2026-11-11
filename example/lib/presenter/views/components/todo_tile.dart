import 'package:flutter/material.dart';
import '../../../domain/entities/todo_entity.dart';

class TodoTile extends StatelessWidget {
  final TodoEntity todo;
  final ValueChanged<bool?> onToggle;
  final VoidCallback onDelete;

  const TodoTile({
    super.key,
    required this.todo,
    required this.onToggle,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      elevation: 1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      child: ListTile(
        leading: Checkbox(
          value: todo.check,
          onChanged: onToggle,
          activeColor: Colors.teal,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
        ),
        title: Text(
          todo.task,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w500,
            decoration: todo.check ? TextDecoration.lineThrough : null,
            color: todo.check ? Colors.grey : Colors.black87,
          ),
        ),
        trailing: IconButton(
          icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
          onPressed: onDelete,
          tooltip: 'Excluir tarefa',
        ),
      ),
    );
  }
}

