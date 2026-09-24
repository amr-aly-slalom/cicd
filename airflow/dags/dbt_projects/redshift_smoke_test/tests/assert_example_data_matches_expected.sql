-- Retrieves example_data via dbt's own test framework and verifies it
-- round-tripped correctly - this is the "read" half of the smoke test
-- (models/example_data.sql's CREATE TABLE AS SELECT is the "write" half).
--
-- A dbt singular test fails if it returns any rows, so this selects the
-- symmetric difference between what we wrote and what's actually there:
-- any row on either side alone means something's missing, extra, or wrong.
with expected as (
    select 1 as id, 'alpha' as name, 10.5 as value
    union all
    select 2, 'bravo', 20.25
    union all
    select 3, 'charlie', 30.75
),

actual as (
    select id, name, value from {{ ref('example_data') }}
)

select * from expected
except
select * from actual

union all

select * from actual
except
select * from expected
