"""
Glue PySpark job: periodic Iceberg table maintenance — compacts small data
files and expires old snapshots for every table in the curated database.

Run infrequently (daily), separately from the merge job (which runs much
more often and would make compaction wasteful if bundled together — most
merge runs only touch a handful of rows).
"""

import sys
import json

from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext
from awsglue.context import GlueContext
from awsglue.job import Job

args = getResolvedOptions(
    sys.argv,
    [
        "JOB_NAME",
        "target_database",
        "table_configs",
        "snapshot_retention_hours",
    ],
)

sc = SparkContext()
glueContext = GlueContext(sc)
spark = glueContext.spark_session
job = Job(glueContext)
job.init(args["JOB_NAME"], args)

TARGET_DATABASE = args["target_database"]
TABLE_NAMES = list(json.loads(args["table_configs"]).keys())
RETENTION_HOURS = int(args["snapshot_retention_hours"])

for table_name in TABLE_NAMES:
    iceberg_table = f"glue_catalog.{TARGET_DATABASE}.{table_name}"

    existing_tables = [
        row.tableName
        for row in spark.sql(f"SHOW TABLES IN glue_catalog.{TARGET_DATABASE}").collect()
    ]
    if table_name not in existing_tables:
        print(f"{iceberg_table} doesn't exist yet — skipping.")
        continue

    print(f"--- Maintaining {iceberg_table} ---")

    # Compacts small files (e.g. the many tiny files a low-volume table like
    # mdo_guardrail_properties accumulates) into fewer, larger ones.
    spark.sql(f"CALL glue_catalog.system.rewrite_data_files(table => '{TARGET_DATABASE}.{table_name}')").show()

    # Drops old snapshots older than the retention window, reclaiming space
    # from files no longer referenced by any snapshot.
    spark.sql(
        f"""
        CALL glue_catalog.system.expire_snapshots(
            table => '{TARGET_DATABASE}.{table_name}',
            older_than => TIMESTAMP '{{now_minus_retention}}',
            retain_last => 1
        )
        """.replace(
            "{now_minus_retention}",
            spark.sql(f"SELECT CAST(current_timestamp() - INTERVAL {RETENTION_HOURS} HOURS AS STRING)").collect()[0][0],
        )
    ).show()

    print(f"Maintenance complete for {iceberg_table}")

job.commit()
