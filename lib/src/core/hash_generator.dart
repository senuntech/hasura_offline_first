import 'dart:convert';
import 'package:crypto/crypto.dart';

/// Utility to generate deterministic SHA-256 hashes for GraphQL queries and variables.
class HashGenerator {
  const HashGenerator();

  /// Generates a SHA-256 hex string based on normalized [document] and deterministic [variables].
  static String generate(String document, [Map<String, dynamic>? variables]) {
    final normalizedDoc = normalizeDocument(document);
    final sortedVars = variables != null ? sortMap(variables) : <String, dynamic>{};
    final serializedVars = jsonEncode(sortedVars);

    final input = '$normalizedDoc|$serializedVars';
    final bytes = utf8.encode(input);
    final digest = sha256.convert(bytes);
    return digest.toString();
  }

  /// Normalizes whitespace and comments in GraphQL documents.
  static String normalizeDocument(String document) {
    return document
        .replaceAll(RegExp(r'#[^\n\r]*'), '') // Remove GraphQL comments
        .replaceAll(RegExp(r'\s+'), ' ')       // Collapse whitespace
        .trim();
  }

  /// Recursively sorts map keys to guarantee deterministic JSON output.
  static Map<String, dynamic> sortMap(Map<String, dynamic> map) {
    final sortedKeys = map.keys.toList()..sort();
    final result = <String, dynamic>{};

    for (final key in sortedKeys) {
      final value = map[key];
      if (value is Map<String, dynamic>) {
        result[key] = sortMap(value);
      } else if (value is Map) {
        result[key] = sortMap(Map<String, dynamic>.from(value));
      } else if (value is List) {
        result[key] = _sortList(value);
      } else {
        result[key] = value;
      }
    }

    return result;
  }

  static List<dynamic> _sortList(List<dynamic> list) {
    return list.map((item) {
      if (item is Map<String, dynamic>) {
        return sortMap(item);
      } else if (item is Map) {
        return sortMap(Map<String, dynamic>.from(item));
      } else if (item is List) {
        return _sortList(item);
      }
      return item;
    }).toList();
  }
}

