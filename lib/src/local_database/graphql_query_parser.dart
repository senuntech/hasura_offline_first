/// Translates GraphQL query arguments into SQLite query parameters.
class GraphQLQueryParser {
  /// Extracts the `where` argument from a GraphQL document or variables
  /// and converts it to a SQL `WHERE` clause and argument list.
  static ParsedWhere? parseWhere(
    String document, [
    Map<String, dynamic>? variables,
  ]) {
    final whereContent = _extractBalancedBraces(document, 'where');
    if (whereContent == null || whereContent.trim().isEmpty) {
      // Fallback for primary key queries: e.g. user_by_pk(id: $id) or (id: "123")
      final pkMatch = RegExp(r'\(\s*(?:pk_columns\s*:\s*\{)?\s*id\s*:\s*([^,\}\)]+)')
          .firstMatch(document);
      if (pkMatch != null) {
        final rawVal = pkMatch.group(1)!.trim();
        dynamic val;
        if (rawVal.startsWith(r'$')) {
          val = variables?[rawVal.substring(1)];
        } else {
          val = _parseLiteral(rawVal);
        }
        if (val != null) {
          return ParsedWhere(
            clause: '"id" = ?',
            args: [_normalizeSqliteValue(val)],
          );
        }
      }
      return null;
    }

    final conditions = <String>[];
    final args = <dynamic>[];

    // Pattern for column: { operator: value } or column: { _is_null: true/false }
    final clauseRegex = RegExp(
      r'([a-zA-Z0-9_]+)\s*:\s*\{\s*(_[a-zA-Z0-9_]+)\s*:\s*([^}]+)\s*\}',
    );

    for (final match in clauseRegex.allMatches(whereContent)) {
      final column = match.group(1)!.trim();
      final op = match.group(2)!.trim();
      final rawValue = match.group(3)!.trim();

      // Resolve variables if rawValue starts with $
      dynamic resolvedValue;
      if (rawValue.startsWith(r'$')) {
        final varName = rawValue.substring(1);
        resolvedValue = variables?[varName];
      } else {
        resolvedValue = _parseLiteral(rawValue);
      }

      switch (op) {
        case '_eq':
          conditions.add('"$column" = ?');
          args.add(_normalizeSqliteValue(resolvedValue));
          break;
        case '_neq':
          conditions.add('"$column" != ?');
          args.add(_normalizeSqliteValue(resolvedValue));
          break;
        case '_gt':
          conditions.add('"$column" > ?');
          args.add(_normalizeSqliteValue(resolvedValue));
          break;
        case '_gte':
          conditions.add('"$column" >= ?');
          args.add(_normalizeSqliteValue(resolvedValue));
          break;
        case '_lt':
          conditions.add('"$column" < ?');
          args.add(_normalizeSqliteValue(resolvedValue));
          break;
        case '_lte':
          conditions.add('"$column" <= ?');
          args.add(_normalizeSqliteValue(resolvedValue));
          break;
        case '_like':
        case '_ilike':
          conditions.add('"$column" LIKE ?');
          args.add(resolvedValue?.toString());
          break;
        case '_is_null':
          final isNull = resolvedValue == true || resolvedValue == 'true';
          conditions.add('"$column" ${isNull ? 'IS NULL' : 'IS NOT NULL'}');
          break;
        default:
          conditions.add('"$column" = ?');
          args.add(_normalizeSqliteValue(resolvedValue));
      }
    }

    if (conditions.isEmpty) return null;

    return ParsedWhere(
      clause: conditions.join(' AND '),
      args: args,
    );
  }

  static String? _extractBalancedBraces(String source, String trigger) {
    final idx = source.indexOf(trigger);
    if (idx == -1) return null;
    final start = source.indexOf('{', idx);
    if (start == -1) return null;

    int depth = 0;
    for (int i = start; i < source.length; i++) {
      if (source[i] == '{') {
        depth++;
      } else if (source[i] == '}') {
        depth--;
        if (depth == 0) {
          return source.substring(start + 1, i);
        }
      }
    }
    return null;
  }

  /// Extracts `order_by` from a GraphQL document.
  static String? parseOrderBy(String document) {
    final orderMatch =
        RegExp(r'order_by\s*:\s*\{([^}]+)\}').firstMatch(document);
    if (orderMatch != null) {
      final inner = orderMatch.group(1)?.trim();
      if (inner != null) {
        final colMatch =
            RegExp(r'([a-zA-Z0-9_]+)\s*:\s*(asc|desc)', caseSensitive: false)
                .firstMatch(inner);
        if (colMatch != null) {
          final col = colMatch.group(1);
          final dir = colMatch.group(2)?.toUpperCase();
          return '"$col" $dir';
        }
      }
    }
    return null;
  }

  /// Extracts `limit` from a GraphQL document.
  static int? parseLimit(String document) {
    final match = RegExp(r'limit\s*:\s*(\d+)').firstMatch(document);
    if (match != null) {
      return int.tryParse(match.group(1)!);
    }
    return null;
  }

  /// Extracts `offset` from a GraphQL document.
  static int? parseOffset(String document) {
    final match = RegExp(r'offset\s*:\s*(\d+)').firstMatch(document);
    if (match != null) {
      return int.tryParse(match.group(1)!);
    }
    return null;
  }

  static dynamic _parseLiteral(String raw) {
    if (raw.toLowerCase() == 'true') return true;
    if (raw.toLowerCase() == 'false') return false;
    if (raw.toLowerCase() == 'null') return null;

    final intVal = int.tryParse(raw);
    if (intVal != null) return intVal;

    final doubleVal = double.tryParse(raw);
    if (doubleVal != null) return doubleVal;

    // Strips string quotes if present
    if ((raw.startsWith('"') && raw.endsWith('"')) ||
        (raw.startsWith("'") && raw.endsWith("'"))) {
      return raw.substring(1, raw.length - 1);
    }

    return raw;
  }

  /// Detects whether a GraphQL document contains nested selection blocks (joins/relations).
  /// For instance: `user_enterprise { id_user enterprise { name } }` contains a nested selection block.
  /// Ignores any braces inside argument parentheses e.g. `(where: { ... })`.
  static bool hasNestedSelections(String document) {
    final cleanDoc = document.replaceAll(RegExp(r'#[^\n\r]*'), '');
    int parenDepth = 0;
    int braceDepth = 0;

    for (int i = 0; i < cleanDoc.length; i++) {
      final char = cleanDoc[i];
      if (char == '(') {
        parenDepth++;
      } else if (char == ')') {
        if (parenDepth > 0) parenDepth--;
      } else if (parenDepth == 0) {
        if (char == '{') {
          braceDepth++;
          if (braceDepth >= 3) {
            // 1st '{': Operation root
            // 2nd '{': Root table selection
            // 3rd '{': Nested object / list relation selection
            return true;
          }
        } else if (char == '}') {
          if (braceDepth > 0) braceDepth--;
        }
      }
    }
    return false;
  }

  static dynamic _normalizeSqliteValue(dynamic value) {
    if (value is bool) {
      return value ? 1 : 0;
    }
    return value;
  }
}

/// Result of parsing a GraphQL `where` argument.
class ParsedWhere {
  final String clause;
  final List<dynamic> args;

  const ParsedWhere({
    required this.clause,
    required this.args,
  });
}
