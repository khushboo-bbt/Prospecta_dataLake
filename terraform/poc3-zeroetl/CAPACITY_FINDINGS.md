# Finding: base capacity 8 RPU is unworkable for POC3 — 16 RPU is the confirmed floor

**Status: RESOLVED.** This started as a draft AWS Support case (never filed) when the symptoms
looked like a possible AWS-side defect. Root-caused and fixed by raising Redshift Serverless base
capacity from 8 to 16 RPU. Kept here as a permanent record for deliverables D9 (Validation
Report) and D10/D11 (Measured Cost Report, Comparative Evaluation) — the SOW's Table 12.3 costs
POC3 at base 8 RPU ($1,454.79/month); the real, working configuration is double that.

## What was observed at base capacity 8 RPU

On the Redshift Serverless workgroup hosting the POC3 zero-ETL destination database (198 in-scope
tables, schema `167597`):

1. **Silent wrong answers.** `SELECT count(*)` against tables in `Synced` state with confirmed
   non-zero `table_rows` (per `SVV_INTEGRATION_TABLE_STATE`) returned **0** — no error, `Status:
   FINISHED`, ~0.3s duration. Cross-checked against `SVV_TABLE_INFO` (Redshift's own storage
   layer, independent of integration self-reporting): the data physically existed on disk with
   the correct size and row count (e.g. `databasechangelog`: 279 rows on disk, exactly matching
   the source; `SELECT count(*)` still returned 0).
2. **Out Of Memory on trivial queries**, including a plain `SVV_TABLE_INFO` catalog/metadata
   query against an otherwise-idle workgroup — four distinct `alloc(...)` failures observed in
   total (`MtFetcherBuffers`, `MtExecPlanPoolCN`, plus two during table replication).
3. **2 of 198 tables failed to replicate** with the same `alloc(...)` signature
   (`crud_table_mapping`: `alloc(10272,MtPlan)`; `delta_sync_child_logs`:
   `alloc(320,MtQueryStats)`).

This is a materially dangerous failure mode for a BI reporting layer: a report built against (1)
would have silently shown "no data" rather than erroring, with nothing to indicate anything was
wrong.

## Resolution

Raised `redshift_base_capacity` from 8 to 16 (`terraform.tfvars`). All of the above resolved:
queries returned correct row counts, no further OOM errors, and the 2 previously-failed tables
recovered automatically on retry (196 → 198 Synced with 16 RPU).

**16 RPU is the confirmed floor, not an estimate.** Redshift Serverless base capacity moves in
8-RPU increments (8, 16, 24, ...) — there is no intermediate value to test between 8 (fails) and
16 (works). Do not reduce below 16.

## Cost implication (for D10/D11)

| | SOW Table 12.3 assumption | Confirmed working |
|---|---|---|
| Base capacity | 8 RPU | 16 RPU |
| Monthly run rate | $1,454.79 | ~$2,909.58 (2x) |

This should be reflected in the Measured Cost Report and the Comparative Evaluation — POC3's
real cost basis is double what the SOW's cost table assumed at the time of proposal.

## Other findings from this investigation, unrelated to capacity

- The resource-policy authorizing the source RDS instance on the Redshift Serverless namespace
  could not be set via `aws redshift-serverless put-resource-policy`, `aws redshift
  put-resource-policy`, or the console's guided "Add authorized principals" form — all three
  failed with different, sometimes contradictory errors (`InvalidPolicyException: Resources are
  not allowed`; `ValidationException: Invalid Policy`; `InvalidPolicyFault: The resource policy
  can't be parsed`) against the original namespace, even for content matching AWS's own
  documented sample. The integration was ultimately created via the RDS console's "Fix it for me"
  option (which sets the resource policy correctly on the backend) against a freshly recreated
  namespace, then imported into Terraform (`terraform import aws_rds_integration.poc3 <arn>`).
  `aws_redshiftserverless_resource_policy` is therefore intentionally not managed by Terraform —
  see `redshift.tf`'s comment and the README's manual step for this.
- The EventBridge integration-state event pattern (`source`/`detail-type`) was confirmed against
  real captured events (see `eventbridge.tf`'s comment on `aws_cloudwatch_event_rule.integration_state`):
  `source: "aws.redshift"`, `detail-type: "Redshift Integration Monitoring"` — not
  `"Redshift Integration Event"` as AWS's general documentation samples would suggest.
