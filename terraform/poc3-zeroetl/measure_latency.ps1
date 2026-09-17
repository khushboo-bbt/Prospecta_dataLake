# Measures replication latency for the Zero-ETL integration: deletes any
# prior test row, inserts a fresh one on the source, then polls the Redshift
# destination until it's visible, comparing Redshift's arrival time against
# the row's own inserted_at (recorded by the SOURCE database's
# clock_timestamp() at the moment of commit).
#
# Uses check_latency_row.sql (a file) for the polling query rather than an
# inline --sql string — a prior version of this script used an inline string
# with escaped quotes, which PowerShell mangled, causing every poll to fail
# with query status FAILED. File-based --sql avoids that entirely, same as
# every other query in this session.
#
# Prerequisites: the SSM port-forward tunnel to the source (localhost:15433)
# must already be running in another terminal, psql must be on PATH, and you
# will be prompted for the source DB password twice (delete, then insert).

$ErrorActionPreference = "Stop"

$secretArn = terraform output -raw redshift_admin_secret_arn
$workgroup = "datalake-poc3-workgroup"
$database  = "poc3_zeroetl_target"
$region    = "ap-southeast-1"

Write-Host "Deleting any prior test row on source..."
psql -h localhost -p 15433 -U postgres -d "mdo-core-crud" -f latency_delete_row.sql
if ($LASTEXITCODE -ne 0) { throw "psql delete failed with exit code $LASTEXITCODE" }

Write-Host "Inserting fresh row into source..."
psql -h localhost -p 15433 -U postgres -d "mdo-core-crud" -f latency_insert.sql
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
        --sql file://check_latency_row.sql `
        --region $region | ConvertFrom-Json

    $statementId = $execResult.Id

    do {
        Start-Sleep -Milliseconds 300
        $status = (aws redshift-data describe-statement --id $statementId --region $region | ConvertFrom-Json).Status
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
        $desc = aws redshift-data describe-statement --id $statementId --region $region | ConvertFrom-Json
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
Write-Host "=== Result ==="
Write-Host "Source commit time (clock_timestamp() on postgreslt): $($sourceTimeUtc.ToString('o'))"
Write-Host "First visible in Redshift (this poll's wall clock):   $($visibleTimeUtc.ToString('o'))"
Write-Host "Measured replication latency:                          $($latency.TotalSeconds) seconds"
Write-Host ""
Write-Host "Note: this is an upper bound within +/- $pollIntervalSeconds s (our poll granularity)."
