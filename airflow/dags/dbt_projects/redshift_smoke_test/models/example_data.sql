-- Trivial literal example data, not sourced from anywhere - the point of
-- this model is proving the platform namespace's Redshift credential fetch
-- (DbtOperator's redshift_namespace, see edp_dbt/operators.py) and the
-- schema/GRANTs provisioned for it (terraform/redshift_namespaces.tf) work
-- end-to-end. See e2e_dbt_redshift.py.
--
-- The full round trip: this model's CREATE TABLE AS SELECT is the write
-- half (create + insert in one statement); tests/assert_example_data_matches_expected.sql
-- is the read half, retrieving it back via dbt's own test framework; and
-- dbt_project.yml's on-run-end hook drops the table afterward either way,
-- so the smoke test leaves nothing behind in the namespace's schema.
select 1 as id, 'alpha' as name, 10.5 as value
union all
select 2, 'bravo', 20.25
union all
select 3, 'charlie', 30.75
