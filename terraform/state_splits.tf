# Safety nets for components moved out of this (core) state into their own
# root modules. Each block covers the window where the code has already moved
# but some environment's state hasn't been migrated yet.
#
# Without it, a core plan in an unmigrated environment sees resources in state
# that are no longer in config and proposes destroying them - for the RDS
# instance that means deleting a database (dev/test have deletion_protection
# off). With destroy = false the worst case becomes "core forgets them": the
# real infrastructure is untouched, and the component's own stack will then
# fail loudly trying to create what already exists, instead of anything being
# deleted quietly. In an environment that has been migrated these blocks are
# no-ops, because the addresses are already gone from this state.
#
# Remove each block once every environment (dev, test, uat, prod) has been
# migrated and verified.

# terraform/rds/ - SAP ECC Oracle RDS.
removed {
  from = module.sap_ecc_oracle_rds

  lifecycle {
    destroy = false
  }
}

# terraform/mwaa/redshift_namespaces.tf - Redshift namespace bootstrap.
# terraform_data only, so nothing real is at stake either way: terraform/mwaa
# recreates both, which re-runs the idempotent GRANT bootstrap once per
# namespace. Forgetting rather than destroying just keeps this state's plan
# from showing destroys during the handover.
removed {
  from = terraform_data.redshift_namespace_bootstrap

  lifecycle {
    destroy = false
  }
}

removed {
  from = terraform_data.redshift_namespace_registration_checks

  lifecycle {
    destroy = false
  }
}

# terraform/kafka/ - MSK cluster, topics, producer/consumer/connect IAM, the
# e2e canary and the shared IAM Roles Anywhere profile. Covers every managed
# resource in terraform/kafka/*.tf; the MSK cluster is among them, so a miss
# here would mean proposing to destroy it in an unmigrated environment.
removed {
  from = aws_rolesanywhere_profile.onprem

  lifecycle {
    destroy = false
  }
}

removed {
  from = terraform_data.kafka_unique_name_check

  lifecycle {
    destroy = false
  }
}

removed {
  from = terraform_data.kafka_producer_name_length_check

  lifecycle {
    destroy = false
  }
}

removed {
  from = terraform_data.kafka_connect_name_length_check

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_msk_topic.this

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_msk_topic.kafka_connect_system_topic

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_iam_policy.kafka_producer

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_iam_role.kafka_aws_producer

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_iam_role_policy_attachment.kafka_aws_producer

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_iam_role.kafka_onprem_producer

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_iam_role_policy_attachment.kafka_onprem_producer

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_iam_policy.kafka_consumer

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_iam_role.kafka_aws_consumer

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_iam_role_policy_attachment.kafka_aws_consumer

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_iam_role.kafka_onprem_consumer

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_iam_role_policy_attachment.kafka_onprem_consumer

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_iam_policy.kafka_connect

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_iam_role.kafka_aws_connect

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_iam_role_policy_attachment.kafka_aws_connect

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_iam_role.kafka_onprem_connect

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_iam_role_policy_attachment.kafka_onprem_connect

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_iam_policy.kafka_consumer_connect

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_iam_role.kafka_consumer_connect_aws

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_iam_role_policy_attachment.kafka_consumer_connect_aws

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_iam_role.kafka_consumer_connect_onprem

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_iam_role_policy_attachment.kafka_consumer_connect_onprem

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_iam_role.canary_lambda_execution

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_iam_role_policy.canary_lambda_execution

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_security_group.canary_lambda

  lifecycle {
    destroy = false
  }
}

removed {
  from = terraform_data.build_kafka_canary_zip

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_s3_object.canary_lambda

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_cloudwatch_log_group.kafka_e2e_canary

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_lambda_function.kafka_e2e_canary

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_cloudwatch_event_rule.kafka_e2e_canary

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_cloudwatch_event_target.kafka_e2e_canary

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_lambda_permission.canary_eventbridge

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_cloudwatch_metric_alarm.kafka_e2e_test_failure

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_cloudwatch_metric_alarm.canary_lambda_errors

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_security_group.msk

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_cloudwatch_log_group.msk

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_msk_configuration.this

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_msk_cluster.this

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_appautoscaling_target.msk_storage

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_appautoscaling_policy.msk_storage

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_cloudwatch_metric_alarm.msk_per_broker

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_cloudwatch_metric_alarm.msk_offline_partitions

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_cloudwatch_metric_alarm.msk_active_controller

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_cloudwatch_dashboard.msk_cluster

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_cloudwatch_dashboard.msk_topics

  lifecycle {
    destroy = false
  }
}

# terraform/lakeformation/ - Lake Formation settings, LF-tags and permissions,
# the Redshift/S3 Tables federated catalogs and the permissions verifier.
# Covers every managed resource and module in terraform/lakeformation/*.tf.
removed {
  from = aws_lakeformation_identity_center_configuration.integration

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_iam_role.lf_data_access

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_iam_role_policy.s3tables_access

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_lakeformation_data_lake_settings.this

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_lakeformation_resource.s3tables_registration

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_glue_catalog.s3tables_federated_catalog

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_iam_role.redshift_data_transfer

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_iam_role_policy.redshift_data_transfer

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_redshift_namespace_registration.this

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_redshift_data_share_consumer_association.this

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_lakeformation_resource.datashare

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_glue_catalog.redshift_federated_catalog

  lifecycle {
    destroy = false
  }
}

removed {
  from = terraform_data.lakeformation_known_kinds_check

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_lakeformation_permissions.database_table_access

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_lakeformation_permissions.access_grants

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_lakeformation_resource_lf_tags.tag_assignments

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_lakeformation_lf_tag.this

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_lakeformation_lf_tag.baseline_governance_tags

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_iam_role.lf_verifier_setup

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_iam_role.lf_verifier_target_resource_permission

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_iam_role.lf_verifier_target_lf_tag

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_s3tables_namespace.lf_verifier

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_lakeformation_lf_tag.lf_verifier_access

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_lakeformation_resource_lf_tags.lf_verifier_access_s3tables_database

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_lakeformation_resource_lf_tags.lf_verifier_access_redshift_database

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_lakeformation_permissions.lf_verifier_setup_s3tables_database

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_lakeformation_permissions.lf_verifier_setup_s3tables_table

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_lakeformation_permissions.lf_verifier_target_resource_permission_s3tables

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_lakeformation_permissions.lf_verifier_target_lf_tag_s3tables

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_lakeformation_permissions.lf_verifier_target_lf_tag_s3tables_database

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_lakeformation_permissions.lf_verifier_target_lf_tag_s3tables_catalog_visibility

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_lakeformation_permissions.lf_verifier_setup_redshift

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_lakeformation_permissions.lf_verifier_target_resource_permission_redshift

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_lakeformation_permissions.lf_verifier_target_lf_tag_redshift

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_lakeformation_permissions.lf_verifier_target_lf_tag_redshift_database

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_lakeformation_permissions.lf_verifier_target_lf_tag_redshift_catalog_visibility

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_iam_role_policy.lf_verifier_setup

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_iam_role_policy.lf_verifier_target_resource_permission

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_iam_role_policy.lf_verifier_target_lf_tag

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_athena_workgroup.lf_verifier

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_iam_role.lf_verifier_lambda_execution

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_iam_role_policy.lf_verifier_lambda_execution

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_cloudwatch_log_group.lf_verifier

  lifecycle {
    destroy = false
  }
}

removed {
  from = terraform_data.build_lf_verifier_zip

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_s3_object.lf_verifier_lambda

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_lambda_function.lf_verifier

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_cloudwatch_event_rule.lf_verifier_schedule

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_cloudwatch_event_target.lf_verifier

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_lambda_permission.lf_verifier_eventbridge

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_cloudwatch_metric_alarm.lf_e2e_s3tables_resource_permission_positive_failure

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_cloudwatch_metric_alarm.lf_e2e_s3tables_resource_permission_negative_failure

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_cloudwatch_metric_alarm.lf_e2e_s3tables_lf_tag_positive_failure

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_cloudwatch_metric_alarm.lf_e2e_s3tables_lf_tag_negative_failure

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_cloudwatch_metric_alarm.lf_e2e_redshift_resource_permission_positive_failure

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_cloudwatch_metric_alarm.lf_e2e_redshift_resource_permission_negative_failure

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_cloudwatch_metric_alarm.lf_e2e_redshift_lf_tag_positive_failure

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_cloudwatch_metric_alarm.lf_e2e_redshift_lf_tag_negative_failure

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_cloudwatch_metric_alarm.lf_e2e_lambda_errors

  lifecycle {
    destroy = false
  }
}

removed {
  from = module.lf_verifier_athena_results_s3

  lifecycle {
    destroy = false
  }
}

# terraform/redshift/ - the Redshift cluster, its master and oggadmin secrets,
# parameter/subnet groups, security group, logging, alarms, IdC application
# and dashboard. Covers every managed resource in terraform/redshift/*.tf; the
# cluster is among them.
removed {
  from = random_password.redshift

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_secretsmanager_secret.redshift_password

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_secretsmanager_secret_version.redshift_password

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_redshift_parameter_group.this

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_redshift_subnet_group.this

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_security_group.redshift

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_cloudwatch_log_group.redshift

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_redshift_cluster.this

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_redshift_logging.this

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_cloudwatch_metric_alarm.redshift

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_iam_role.redshift_idc_svc

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_iam_role_policy.redshift_idc_svc

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_redshift_idc_application.this

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_redshift_resource_policy.zero_etl_inbound

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_redshift_cluster_iam_roles.this

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_secretsmanager_secret.oggadmin

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_secretsmanager_secret_version.oggadmin

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_cloudwatch_dashboard.redshift

  lifecycle {
    destroy = false
  }
}

# terraform/s3tables/ - the S3 Tables bucket, its namespaces and tables, the
# per-namespace producer roles and Athena workgroups, and the E2E verifier.
# Covers every managed resource and module in terraform/s3tables/*.tf; the
# table bucket is among them, so a miss here would mean proposing to destroy
# it (and every table in it) in an unmigrated environment.
removed {
  from = aws_s3tables_table_bucket.this

  lifecycle {
    destroy = false
  }
}

removed {
  from = terraform_data.s3tables_producer_validation

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_iam_role.s3tables_namespace_producer

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_iam_role_policy.s3tables_namespace_producer

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_athena_workgroup.s3tables_namespace

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_iam_role.s3tables_e2e_verifier_lambda_execution

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_iam_role_policy.s3tables_e2e_verifier_lambda_execution

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_iam_role.s3tables_e2e_verifier_producer

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_iam_role_policy.s3tables_e2e_verifier_producer

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_athena_workgroup.s3tables_e2e_verifier

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_cloudwatch_log_group.s3tables_e2e_verifier

  lifecycle {
    destroy = false
  }
}

removed {
  from = terraform_data.build_s3tables_e2e_verifier_zip

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_s3_object.s3tables_e2e_verifier_lambda

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_lambda_function.s3tables_e2e_verifier

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_cloudwatch_event_rule.s3tables_e2e_verifier_schedule

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_cloudwatch_event_target.s3tables_e2e_verifier

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_lambda_permission.s3tables_e2e_verifier_eventbridge

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_cloudwatch_metric_alarm.s3tables_e2e_validation_failure

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_cloudwatch_metric_alarm.s3tables_e2e_cleanup_failure

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_cloudwatch_metric_alarm.s3tables_e2e_lambda_errors

  lifecycle {
    destroy = false
  }
}

removed {
  from = module.table_bucket

  lifecycle {
    destroy = false
  }
}

removed {
  from = module.s3tables_athena_results_s3

  lifecycle {
    destroy = false
  }
}

# terraform/s3/ - S3 producer onboarding: the landing bucket, namespace and
# table producer roles and policies, Athena workgroups, Glue databases and
# tables, and the E2E verifier. Covers every managed resource and module in
# terraform/s3/*.tf; the landing bucket is among them.
removed {
  from = terraform_data.s3_namespace_unique_check

  lifecycle {
    destroy = false
  }
}

removed {
  from = terraform_data.s3_table_unique_check

  lifecycle {
    destroy = false
  }
}

removed {
  from = terraform_data.s3_namespace_name_length_check

  lifecycle {
    destroy = false
  }
}

removed {
  from = terraform_data.s3_table_name_length_check

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_iam_policy.s3_namespace_producer

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_iam_role.s3_namespace_aws_producer

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_iam_role_policy_attachment.s3_namespace_aws_producer

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_iam_role.s3_namespace_onprem_producer

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_iam_role_policy_attachment.s3_namespace_onprem_producer

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_iam_policy.s3_table_producer

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_iam_role.s3_table_aws_producer

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_iam_role_policy_attachment.s3_table_aws_producer

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_iam_role.s3_table_onprem_producer

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_iam_role_policy_attachment.s3_table_onprem_producer

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_athena_workgroup.s3_namespace_producer

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_glue_catalog_database.producer_domain

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_glue_catalog_table.producer_dataset

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_iam_role.s3_e2e_verifier_lambda_execution

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_iam_role_policy.s3_e2e_verifier_lambda_execution

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_cloudwatch_log_group.s3_e2e_verifier

  lifecycle {
    destroy = false
  }
}

removed {
  from = terraform_data.build_s3_verifier_zip

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_s3_object.s3_e2e_verifier_lambda

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_lambda_function.s3_e2e_verifier

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_cloudwatch_event_rule.s3_e2e_verifier_schedule

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_cloudwatch_event_target.s3_e2e_verifier

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_lambda_permission.s3_e2e_verifier_eventbridge

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_cloudwatch_metric_alarm.s3_e2e_validation_failure

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_cloudwatch_metric_alarm.s3_e2e_cleanup_failure

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_cloudwatch_metric_alarm.s3_e2e_lambda_errors

  lifecycle {
    destroy = false
  }
}

removed {
  from = module.landing_s3

  lifecycle {
    destroy = false
  }
}
