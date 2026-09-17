"""
Second of the SOW's two independent sync-failure detection paths for the
POC3 zero-ETL integration (the first is eventbridge.tf's rule on integration
state-change events). Amazon RDS publishes no per-table integration metrics
to CloudWatch, and a table can silently stop synchronising without the
integration itself ever reporting an error — SVV_INTEGRATION_TABLE_STATE is
the only place that per-table state is visible, so this polls it directly.

Invoked on a schedule (eventbridge.tf) via the Redshift Data API, using the
namespace's own Redshift-managed admin secret (no Postgres login involved).
"""

import os
import time

import boto3

redshift_data = boto3.client("redshift-data")
cloudwatch = boto3.client("cloudwatch")

WORKGROUP_NAME = os.environ["WORKGROUP_NAME"]
DATABASE = os.environ["DATABASE"]
SECRET_ARN = os.environ["SECRET_ARN"]
TARGET_DATABASE = os.environ["TARGET_DATABASE"]
INTEGRATION_NAME = os.environ["INTEGRATION_NAME"]

# SVV_INTEGRATION_TABLE_STATE.table_state values (Redshift Database Developer
# Guide): Synced, Failed, Deleted, ResyncRequired, ResyncInitiated,
# DroppedSource. Only Synced counts as healthy.
POLL_INTERVAL_SECONDS = 1
MAX_POLL_ATTEMPTS = 20

# Every character column in this view is bpchar (fixed-length), so values
# come back space-padded — "Synced" arrives as "Synced" followed by ~60
# spaces. Redshift's own = comparison ignores that padding, but Python's does
# not, so TRIM here rather than comparing padded strings below.
SQL = (
    "SELECT trim(schema_name), trim(table_name), trim(table_state), trim(reason) "
    "FROM svv_integration_table_state "
    "WHERE target_database = :target_database;"
)


def handler(event, context):
    statement_id = redshift_data.execute_statement(
        WorkgroupName=WORKGROUP_NAME,
        Database=DATABASE,
        SecretArn=SECRET_ARN,
        Sql=SQL,
        Parameters=[{"name": "target_database", "value": TARGET_DATABASE}],
    )["Id"]

    status = _wait_for_completion(statement_id)
    if status != "FINISHED":
        # The query itself failed to run (e.g. the destination database
        # doesn't exist yet, before sql/01_create_target_database.sql has
        # been run). Raising here — rather than silently reporting zero
        # unsynced tables — surfaces as a Lambda execution error, which
        # monitoring.tf alarms on via the standard AWS/Lambda Errors metric.
        raise RuntimeError(f"redshift-data statement {statement_id} ended in status {status}")

    result = redshift_data.get_statement_result(Id=statement_id)
    rows = result["Records"]

    unsynced = []
    for row in rows:
        table_state = (row[2].get("stringValue") or "").strip()
        if table_state != "Synced":
            unsynced.append(
                {
                    "schema": (row[0].get("stringValue") or "").strip(),
                    "table": (row[1].get("stringValue") or "").strip(),
                    "state": table_state,
                    "reason": (row[3].get("stringValue") or "").strip(),
                }
            )

    _publish_metric("UnsyncedTableCount", len(unsynced))

    if unsynced:
        print(f"Unsynced tables: {unsynced}")

    return {"total_tables": len(rows), "unsynced_tables": len(unsynced)}


def _wait_for_completion(statement_id):
    for _ in range(MAX_POLL_ATTEMPTS):
        description = redshift_data.describe_statement(Id=statement_id)
        status = description["Status"]
        if status in ("FINISHED", "FAILED", "ABORTED"):
            return status
        time.sleep(POLL_INTERVAL_SECONDS)
    return "TIMED_OUT"


def _publish_metric(metric_name, value):
    cloudwatch.put_metric_data(
        Namespace="Custom/ZeroETL",
        MetricData=[
            {
                "MetricName": metric_name,
                "Dimensions": [{"Name": "IntegrationName", "Value": INTEGRATION_NAME}],
                "Value": value,
                "Unit": "Count",
            }
        ],
    )
