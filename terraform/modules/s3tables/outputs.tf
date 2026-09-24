output "namespaces" {
  description = "Map of namespace name as written in YAML => namespace name as created in AWS. When enable_namespace_prefix is true these differ. The AWS name is also the database name the namespace surfaces as in the Glue federated catalog."
  value = {
    for k, ns in aws_s3tables_namespace.this : k => ns.namespace
  }
}

output "tables" {
  description = "Map of created tables, keyed by '<namespace>.<table>'. Every table has prevent_destroy = true unconditionally (see main.tf)."
  value = {
    for k, tbl in aws_s3tables_table.this : k => {
      arn                      = tbl.arn
      namespace                = tbl.namespace
      name                     = tbl.name
      warehouse_location       = tbl.warehouse_location
      metadata_location        = tbl.metadata_location
      encryption_configuration = tbl.encryption_configuration
    }
  }
}

output "table_policies" {
  description = "Set of '<namespace>.<table>' keys that have a table-level resource policy attached."
  value       = keys(aws_s3tables_table_policy.this)
}

output "table_replications" {
  description = "Set of '<namespace>.<table>' keys that have table-level replication configured."
  value       = keys(aws_s3tables_table_replication.this)
}
