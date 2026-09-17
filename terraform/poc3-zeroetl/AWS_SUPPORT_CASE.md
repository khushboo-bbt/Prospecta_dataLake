# AWS Support Case — Zero-ETL tables report `Synced` but return 0 rows, and the workgroup OOMs on catalog queries

**Service**: Amazon Redshift Serverless / Amazon RDS zero-ETL integration
**Region**: ap-southeast-1
**Account**: 448049790823
**Severity suggestion**: Production-impacting for an active evaluation (POC with fixed timeline)

## Summary

Two problems on the same Redshift Serverless workgroup (base capacity 8 RPU), which may share a
root cause:

1. An RDS for PostgreSQL → Redshift Serverless zero-ETL integration reports 196 of 198 tables in
   `Synced` state, with non-zero `table_rows` in `SVV_INTEGRATION_TABLE_STATE`, but `SELECT`
   queries against those tables consistently return **0 rows**. The source tables demonstrably
   contain data.
2. The same workgroup returns **`Out Of Memory`** on trivial queries — including a `SELECT` from
   `SVV_TABLE_INFO` (a catalog/metadata query) — well after the initial backfill completed and
   with no other workload running.

We are specifically **not** raising base capacity above 8 RPU, because 8 RPU is the specified
configuration under evaluation and we need to understand whether this behaviour is expected at
that size.

## Resources

| Item | Value |
|---|---|
| Integration ARN | `arn:aws:rds:ap-southeast-1:448049790823:integration:625b8798-9fff-48bc-9754-f1b76a3eae41` |
| Integration name | `datalake-poc3-zero-etl` |
| Source RDS instance | `postgreslt` (PostgreSQL 16.13) |
| Source database | `mdo-core-crud` |
| Source schema in scope | `167597` |
| Data filter | `include: mdo-core-crud.167597.*` |
| Target namespace ARN | `arn:aws:redshift-serverless:ap-southeast-1:448049790823:namespace/7b208caf-91a8-4cb6-9f19-09cdf80e686d` |
| Target workgroup | `datalake-poc3-workgroup` (base capacity 8 RPU) |
| Destination database | `poc3_zeroetl_target` (created via `CREATE DATABASE ... FROM INTEGRATION`) |
| KMS key | `arn:aws:kms:ap-southeast-1:448049790823:key/0e55c5c0-15de-4299-9e21-e0e9bcc074ea` |

Integration status: `active`. Destination database created successfully.

## Expected vs observed

**Expected**: `SELECT count(*)` against a table in `Synced` state returns the replicated row count.

**Observed**: returns `0`, with no error, for every table tested.

### Evidence — table `167597.databasechangelog`

Source (direct `psql` to the primary instance via SSM port-forward, verified with two separate
logins — `dms_replication_user` and the `postgres` admin user):

```sql
SELECT count(*) FROM "167597".databasechangelog;
-- 279
```

Target (`poc3_zeroetl_target`):

```sql
SELECT count(*) FROM "167597"."databasechangelog";
-- 0
```

### Evidence — table `167597.change_request_header`

`SVV_INTEGRATION_TABLE_STATE` reports:

| schema_name | table_name | table_rows | table_size |
|---|---|---|---|
| 167597 | change_request_header | 18226 | 6400 |

Target query returns `0`. A `SELECT * ... LIMIT 5` against the same table also returns 0 rows
(`ResultRows: 0`, status `FINISHED`, duration ~53s).

### Sync state summary

```sql
SELECT table_state, count(*) FROM svv_integration_table_state
WHERE target_database = 'poc3_zeroetl_target' GROUP BY table_state;
```

| table_state | count |
|---|---|
| Synced | 196 |
| Failed | 2 |

The 2 `Failed` tables report internal allocation errors (see "Related errors" below).

## What we have ruled out

1. **Client tooling** — reproduced identically via the Redshift Data API (twice) and via the
   Redshift console Query Editor v2.
2. **Source data absence** — source verified at 279 rows via direct `psql` with two different
   credentials.
3. **Query/identifier error** — queries execute successfully with no error; a wrong identifier
   under `enable_case_sensitive_identifier = true` would raise "relation does not exist".
4. **Transient capacity pressure** — initially queries were slow (~53s) and one failed with OOM
   (below). After load settled, queries now complete in ~0.3s with no error, still returning 0.
5. **Insufficient wait time** — the condition has persisted across repeated checks over an
   extended period after all tables reached `Synced`.

## Related errors (possibly the same root cause)

Two tables failed to replicate, both with internal allocation errors:

```
167597.crud_table_mapping:
  Amazon Redshift cannot replicate table '167597.crud_table_mapping' because encountered
  'alloc(10272,MtPlan)'. If the issue persists, please contact AWS Redshift Support ...

167597.delta_sync_child_logs:
  Amazon Redshift cannot replicate table '167597.delta_sync_child_logs' because encountered
  'alloc(320,MtQueryStats)'. ...
```

Separately, a `SELECT count(*)` against `167597.databasechangelog` failed once with:

```
ERROR: Out Of Memory:
  code:      1004
  context:   alloc(262144,MtFetcherBuffers)
  query:     612618[child_sequence:1]
  location:  xen_memory.cpp:1064
```

And — most significantly — a **catalog/metadata query** failed the same way, with no other
workload running and long after the backfill had completed:

```sql
SELECT "table", tbl_rows, size, unsorted, stats_off
FROM svv_table_info WHERE "schema" = '167597' ORDER BY size DESC LIMIT 20;
```

```
ERROR: Out Of Memory:
  code:      1004
  context:   alloc(524288,MtExecPlanPoolCN)
  query:     3658403[child_sequence:1]
  location:  xen_memory.cpp:1064
```

A query against `SVV_TABLE_INFO` reads catalog metadata only and should not be capable of
exhausting memory on an otherwise-idle workgroup. All four failures share the `alloc(...)`
signature, which suggests a single underlying memory/resource condition on this workgroup rather
than four independent faults — and raises the possibility that the 0-row results are a
**symptom** of the same condition (queries returning empty results instead of erroring when
allocation fails) rather than a separate replication defect.

## Source configuration (per AWS zero-ETL requirements for RDS for PostgreSQL)

Custom DB parameter group `datalake-poc2-logical-replication`, confirmed `in-sync` on the
instance after reboot:

- `rds.logical_replication = 1`
- `rds.replica_identity_full = 1`
- `session_replication_role = origin`
- `wal_sender_timeout = 0`
- `max_wal_senders = 35`
- `max_replication_slots = 20`
- `max_slot_wal_keep_size = -1`

Target workgroup has `enable_case_sensitive_identifier = true`.

## Relevant history

This integration was created through the RDS console (using the "Fix it for me" option for the
target resource policy) after repeated failures setting the Redshift Serverless namespace
resource policy programmatically:

- `aws redshift-serverless put-resource-policy` rejected every policy shape attempted with
  `InvalidPolicyException: Resources are not allowed` or `ValidationException: Invalid Policy`,
  including the shape documented in the Redshift Management Guide.
- `aws redshift put-resource-policy` and the console's "Add authorized principals" form both
  returned `InvalidPolicyFault: The resource policy can't be parsed.`
- On the original namespace, `get-resource-policy` returned a policy document while
  `delete-resource-policy` reported `ResourceNotFoundException: Resource Policy ... does not exist`.

That original namespace was destroyed and a new one created (the one in this case). The
integration was then created successfully via the console.

## Questions for AWS

1. Why does an otherwise-idle 8 RPU workgroup return `Out Of Memory` on a `SVV_TABLE_INFO`
   catalog query? Is 8 RPU below a supported minimum for a workgroup hosting a zero-ETL
   destination database of this size (198 tables)?
2. Are the 0-row query results a consequence of the same memory condition (i.e. queries silently
   returning empty results when allocation fails), or a separate replication/visibility defect?
3. Why do tables in `Synced` state with non-zero `table_rows` return 0 rows to queries? Is there
   an additional required step between `Synced` state and query visibility for RDS for PostgreSQL
   sources?
4. Can you confirm from your side whether data was physically written to the destination database
   — i.e. does the replicated storage actually contain rows? We have been unable to determine this
   ourselves, since both the data queries and the catalog queries that would answer it fail or
   return 0.
5. What is the correct, working request shape for `PutResourcePolicy` on a Redshift Serverless
   namespace for zero-ETL authorization? The documented example is rejected by the API.
6. Is recreating the integration expected to resolve this, or would it reproduce?

## Note on configuration under test

We have deliberately left base capacity at 8 RPU rather than scaling up to work around the issue,
so that the behaviour can be assessed at the configuration under evaluation. If AWS's position is
that 8 RPU is insufficient for this workload, please state the supported minimum for a zero-ETL
destination workgroup — that is itself the answer we need for our sizing recommendation.
