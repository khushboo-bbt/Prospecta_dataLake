"""
Glue PySpark job: merges DMS-landed raw Parquet (full-load + CDC) from the
`datalake_poc2` catalog into deduplicated Iceberg tables in
`datalake_poc2_curated`.

Generic and table-driven — the actual table list + primary keys come in as
a JSON job argument (--table_configs), not hardcoded here. Add a table by
updating that Terraform variable, not this script.

DMS writes an `op` column on every record (include_op_for_full_load=true on
the target endpoint) — 'I'/blank for insert, 'U' for update, 'D' for delete.
Full-load records and CDC records land in the same source table/column
shape, so both are handled by the same merge logic.

Uses Glue Job Bookmarks (transformation_ctx below) so re-running this job
only processes S3 files it hasn't already seen — the "watermark guard" is
this built-in mechanism, not custom checkpoint code.
"""

import sys
import json

from awsglue.transforms import *
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext
from awsglue.context import GlueContext
from awsglue.job import Job

args = getResolvedOptions(
    sys.argv,
    [
        "JOB_NAME",
        "source_database",
        "target_database",
        "iceberg_warehouse_path",
        "table_configs",
    ],
)

sc = SparkContext()
glueContext = GlueContext(sc)
spark = glueContext.spark_session
job = Job(glueContext)
job.init(args["JOB_NAME"], args)

SOURCE_DATABASE = args["source_database"]
TARGET_DATABASE = args["target_database"]
TABLE_CONFIGS = json.loads(args["table_configs"])  # {"table_name": {"pk": ["col1","col2"], "append_only": false}}

spark.sql(f"CREATE DATABASE IF NOT EXISTS glue_catalog.{TARGET_DATABASE}")

for table_name, config in TABLE_CONFIGS.items():
    pk_columns = config["pk"]
    append_only = config.get("append_only", False)

    print(f"--- Processing {table_name} (pk={pk_columns}, append_only={append_only}) ---")

    source_dyf = glueContext.create_dynamic_frame.from_catalog(
        database=SOURCE_DATABASE,
        table_name=table_name,
        transformation_ctx=f"read_{table_name}",
    )

    if source_dyf.count() == 0:
        print(f"No new records for {table_name} since last bookmark — skipping.")
        continue

    source_df = source_dyf.toDF()
    iceberg_table = f"glue_catalog.{TARGET_DATABASE}.{table_name}"
    # spark.catalog.tableExists()/_jsparkSession.catalog() check Spark's
    # default built-in catalog, not our custom "glue_catalog" Iceberg
    # catalog — always returns False for these tables regardless of whether
    # they actually exist, since they live in a different catalog entirely.
    # Check via SHOW TABLES against the actual catalog instead.
    existing_tables = [
        row.tableName
        for row in spark.sql(f"SHOW TABLES IN glue_catalog.{TARGET_DATABASE}").collect()
    ]
    table_exists = table_name in existing_tables

    if append_only:
        # Audit/history-style tables: every row is a new fact, never merged
        # or deduped — matches Hibernate Envers *_aud semantics where each
        # "rev" must be preserved, not collapsed.
        writer = source_df.writeTo(iceberg_table)
        if table_exists:
            writer.append()
        else:
            writer.using("iceberg").create()
        print(f"Appended {source_df.count()} rows to {iceberg_table}")
        continue

    if not table_exists:
        # First run for this table: no target to merge into yet, so the
        # initial full load just becomes the table directly.
        source_df.writeTo(iceberg_table).using("iceberg").create()
        print(f"Created {iceberg_table} with {source_df.count()} initial rows")
        continue

    source_df.createOrReplaceTempView(f"src_{table_name}")

    on_clause = " AND ".join([f"t.{c} = s.{c}" for c in pk_columns])
    non_pk_cols = [c for c in source_df.columns if c not in pk_columns and c != "op"]
    update_set = ", ".join([f"t.{c} = s.{c}" for c in non_pk_cols])
    insert_cols = [c for c in source_df.columns if c != "op"]
    insert_col_list = ", ".join(insert_cols)
    insert_val_list = ", ".join([f"s.{c}" for c in insert_cols])

    merge_sql = f"""
        MERGE INTO {iceberg_table} t
        USING src_{table_name} s
        ON {on_clause}
        WHEN MATCHED AND s.op = 'D' THEN DELETE
        WHEN MATCHED THEN UPDATE SET {update_set}
        WHEN NOT MATCHED AND (s.op IS NULL OR s.op != 'D') THEN INSERT ({insert_col_list}) VALUES ({insert_val_list})
    """
    spark.sql(merge_sql)
    print(f"Merged {source_df.count()} candidate rows into {iceberg_table}")

job.commit()
