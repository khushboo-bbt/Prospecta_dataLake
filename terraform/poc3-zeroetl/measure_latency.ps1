# Measures replication latency for the Zero-ETL integration: inserts ONE
# fresh row (a new, never-before-used id each run) into a dedicated,
# disposable test table on the source, then polls the Redshift destination
# until it's visible, comparing Redshift's arrival time against the row's
# own inserted_at (recorded by the SOURCE database's clock_timestamp() at
# the moment of commit).
#
# Deliberately does NOT delete/reuse the same id between runs. An earlier
# version of this script did a DELETE + INSERT of the same id=1 each time,
# which appears to trigger a brief resync/transitional state on the table —
# Redshift then blocks querying it at all ("table is not available for
# querying right now ... run ALTER DATABASE with QUERY_ALL_STATES=TRUE") until
# it settles back to Synced. A pure INSERT of a new id has no such effect.
#
# Prerequisites: the SSM port-forward tunnel to the source (localhost:15433)
# must already be running in another terminal, psql must be on PATH, and you
# will be prompted once for the source DB password.

$ErrorActionPreference = "Stop"

$secretArn = terraform output -raw redshift_admin_secret_arn
$workgroup = "datalake-poc3-workgroup"
$database  = "poc3_zeroetl_target"
$region    = "ap-southeast-1"

# Unique id per run: seconds since epoch, safely fits in a Postgres integer
# until the year 2038 and is unique enough for a handful of manual test runs.
$testId = [int][double]::Parse((Get-Date -UFormat %s))

$insertSqlPath = "latency_insert_run.sql"
$checkSqlPath  = "check_latency_row_run.sql"

"INSERT INTO ""167597"".zero_etl_latency_test (id) VALUES ($testId);" | Set-Content -Path $insertSqlPath -Encoding ascii
"SELECT inserted_at FROM ""167597"".zero_etl_latency_test WHERE id = $testId;" | Set-Content -Path $checkSqlPath -Encoding ascii

Write-Host "Test row id for this run: $testId"
Write-Host "Inserting into source (you will be prompted for the password)..."
psql -h localhost -p 15433 -U postgres -d "mdo-core-crud" -f $insertSqlPath
if ($LASTEXITCODE -ne 0) { throw "psql insert failed with exit code $LASTEXITCODE" }
Write-Host "Insert complete on source."

Write-Host "Polling Redshift destination for the row to appear..."
$pollIntervalSeconds = 2
$maxPolls = 150
$found = $false

for ($i = 0; $i -lt $maxPolls; $i++) {
    $execResult = aws redshift-data execute-statement `
        --workgroup-name $workgroup `
        --database $database `
        --secret-arn $secretArn `
        --sql file://$checkSqlPath `
        --region $region | ConvertFrom-Json

    $statementId = $execResult.Id

    do {
        Start-Sleep -Milliseconds 300
        $desc = aws redshift-data describe-statement --id $statementId --region $region | ConvertFrom-Json
        $status = $desc.Status
    } while ($status -eq "STARTED" -or $status -eq "SUBMITTED" -or $status -eq "PICKED")

    if ($status -eq "FINISHED") {
        $result = aws redshift-data get-statement-result --id $statementId --region $region | ConvertFrom-Json
        if ($result.Records.Count -gt 0) {
            $visibleTime = Get-Date
            $sourceInsertedAt = $result.Records[0][0].stringValue
            $found = $true
            break
        }
        else {
            Write-Host "  poll $i : not yet visible"
        }
    }
    else {
        Write-Host "  poll $i : query status $status ($($desc.Error))"
    }

    Start-Sleep -Seconds $pollIntervalSeconds
}

if (-not $found) {
    Write-Host "TIMED OUT after $($maxPolls * $pollIntervalSeconds) seconds — row never became visible in Redshift."
    exit 1
}

$sourceTimeUtc = [DateTime]::SpecifyKind([DateTime]::Parse($sourceInsertedAt), [DateTimeKind]::Utc)
$visibleTimeUtc = $visibleTime.ToUniversalTime()
$latency = $visibleTimeUtc - $sourceTimeUtc

Write-Host ""
Write-Host "=== Result (test id $testId) ==="
Write-Host "Source commit time (clock_timestamp() on postgreslt): $($sourceTimeUtc.ToString('o'))"
Write-Host "First visible in Redshift (this poll's wall clock):   $($visibleTimeUtc.ToString('o'))"
Write-Host "Measured replication latency:                          $($latency.TotalSeconds) seconds"
Write-Host ""
Write-Host "Note: this is an upper bound within +/- $pollIntervalSeconds s (our poll granularity)."
