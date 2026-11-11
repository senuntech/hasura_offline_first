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
