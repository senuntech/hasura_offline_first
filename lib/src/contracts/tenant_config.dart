import 'dart:convert';

/// Configuration for Multi-Tenant scenarios.
///
/// When provided to [HasuraOfflineFirst], data is isolated physically in a dedicated
/// SQLite database (`hasura_tenant_<tenantId>.db`), and pull queries automatically scope
/// results to [tenantId] via [tenantColumn].
class TenantConfig {
  /// Unique identifier of the tenant / organization / workspace / user.
  final String tenantId;

  /// The column name in the Hasura table representing the tenant (defaults to 'tenant_id').
  final String tenantColumn;

  /// Whether to automatically inject [tenantColumn: tenantId] when inserting records
  /// locally if not already specified. Defaults to `true`.
  final bool autoInjectTenantOnInsert;

  const TenantConfig({
    required this.tenantId,
    this.tenantColumn = 'tenant_id',
    this.autoInjectTenantOnInsert = true,
  });

  /// Factory constructor that automatically decodes a Hasura JWT token and extracts
  /// the tenant identifier.
  ///
  /// Searches for [claimName] (defaults to `'x-hasura-tenant-id'`) inside:
  /// 1. `https://hasura.io/jwt/claims` (Standard Hasura namespace)
  /// 2. Root level claims in the JWT payload (fallback)
  ///
  /// Throws a [FormatException] if the token is invalid or the claim is missing.
  factory TenantConfig.fromJwt(
    String rawToken, {
    String claimName = 'x-hasura-tenant-id',
    String tenantColumn = 'tenant_id',
    bool autoInjectTenantOnInsert = true,
  }) {
    final token = rawToken.startsWith('Bearer ')
        ? rawToken.substring(7).trim()
        : rawToken.trim();

    final parts = token.split('.');
    if (parts.length < 2) {
      throw const FormatException('Invalid JWT token format');
    }

    final payloadNormalized = base64Url.normalize(parts[1]);
    final payloadString = utf8.decode(base64Url.decode(payloadNormalized));
    final Map<String, dynamic> payload = jsonDecode(payloadString);

    String? extractedTenantId;

    // 1. Hasura standard namespace
    final hasuraClaims = payload['https://hasura.io/jwt/claims'];
    if (hasuraClaims is Map) {
      extractedTenantId = hasuraClaims[claimName]?.toString();
    }

    // 2. Fallback to root level
    extractedTenantId ??= payload[claimName]?.toString();

    if (extractedTenantId == null || extractedTenantId.isEmpty) {
      throw FormatException(
        'Tenant claim "$claimName" not found in JWT payload or Hasura claims namespace.',
      );
    }

    return TenantConfig(
      tenantId: extractedTenantId,
      tenantColumn: tenantColumn,
      autoInjectTenantOnInsert: autoInjectTenantOnInsert,
    );
  }

  /// Attempts to extract a [TenantConfig] from a JWT token or header string.
  /// Returns `null` if the token is not a valid JWT or does not contain the tenant claim.
  static TenantConfig? tryFromJwt(
    String? rawToken, {
    String claimName = 'x-hasura-tenant-id',
    String tenantColumn = 'tenant_id',
    bool autoInjectTenantOnInsert = true,
  }) {
    if (rawToken == null || rawToken.isEmpty) return null;
    try {
      return TenantConfig.fromJwt(
        rawToken,
        claimName: claimName,
        tenantColumn: tenantColumn,
        autoInjectTenantOnInsert: autoInjectTenantOnInsert,
      );
    } catch (_) {
      return null;
    }
  }

  TenantConfig copyWith({
    String? tenantId,
    String? tenantColumn,
    bool? autoInjectTenantOnInsert,
  }) {
    return TenantConfig(
      tenantId: tenantId ?? this.tenantId,
      tenantColumn: tenantColumn ?? this.tenantColumn,
      autoInjectTenantOnInsert:
          autoInjectTenantOnInsert ?? this.autoInjectTenantOnInsert,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TenantConfig &&
          runtimeType == other.runtimeType &&
          tenantId == other.tenantId &&
          tenantColumn == other.tenantColumn &&
          autoInjectTenantOnInsert == other.autoInjectTenantOnInsert;

  @override
  int get hashCode =>
      tenantId.hashCode ^
      tenantColumn.hashCode ^
      autoInjectTenantOnInsert.hashCode;
}

