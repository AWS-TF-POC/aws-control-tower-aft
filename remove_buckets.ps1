#!/usr/bin/env pwsh
Set-StrictMode -Version Latest

# Load Terraform outputs
$AFT_MGMT_ACCT = (terraform output -raw aft_management_account_id) -as [string]
$LOG_ACCT = (terraform output -raw log_archive_account_id) -as [string]
$REGION = (terraform output -raw region) -as [string]
$env:AWS_PAGER = ""

if ($AFT_MGMT_ACCT -match 'Warning') {
    Write-Host '$AFT_MGMT_ACCT is empty. Run ''terraform refresh''' -ForegroundColor Yellow
    exit 1
}
if ($LOG_ACCT -match 'Warning') {
    Write-Host '$LOG_ACCT is empty. Run ''terraform refresh''' -ForegroundColor Yellow
    exit 1
}

# Ensure AWS config profiles exist
$awsConfig = Join-Path $HOME ".aws\config"
if (-not (Test-Path $awsConfig) -or -not (Select-String -Path $awsConfig -Pattern 'aft-log-acct' -Quiet -ErrorAction SilentlyContinue)) {
    if (-not (Test-Path (Split-Path $awsConfig))) { New-Item -ItemType Directory -Path (Split-Path $awsConfig) -Force | Out-Null }
    @"
[profile aft-log-acct]
source_profile = default
role_arn = arn:aws:iam::${LOG_ACCT}:role/AWSControlTowerExecution
[profile aft-mgmt-acct]
source_profile = default
role_arn = arn:aws:iam::${AFT_MGMT_ACCT}:role/AWSControlTowerExecution
"@ | Out-File -FilePath $awsConfig -Append -Encoding utf8
}

$env:AWS_PROFILE = 'aft-mgmt-acct'

Write-Host "Region: $REGION" -ForegroundColor Cyan

## Delete vault backups
$VAULT_NAME = 'aft-controltower-backup-vault'
$arnsRaw = aws backup list-recovery-points-by-backup-vault --region $REGION --backup-vault-name $VAULT_NAME --query 'RecoveryPoints[].RecoveryPointArn' --output text 2>&1
if ($arnsRaw -and ($arnsRaw -notmatch 'NoSuchVault') -and ($arnsRaw -notmatch 'NoSuchEntity')) {
    $arns = $arnsRaw -split "\s+" | Where-Object { $_ -ne '' }
    foreach ($ARN in $arns) {
        Write-Host "Deleting backup $ARN ..."
        aws backup delete-recovery-point --region $REGION --backup-vault-name $VAULT_NAME --recovery-point-arn $ARN
    }
}

# Deleting items in AFT Management Account
$AFT_MGMT_BUCKETS = @(
    "aft-customizations-pipeline-${AFT_MGMT_ACCT}",
    "aft-backend-${AFT_MGMT_ACCT}-primary-region",
    "aft-backend-${AFT_MGMT_ACCT}-secondary-region"
)

function Remove-BucketContentsAndDelete {
    param(
        [string]$bucket,
        [string]$region
    )
    Write-Host "Processing bucket: $bucket"

    $bucketVersionStatus = aws s3api list-object-versions --bucket $bucket --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' 2>&1
    $bucketMarkersStatus = aws s3api list-object-versions --bucket $bucket --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}' 2>&1

    if ($bucketVersionStatus -and ($bucketVersionStatus -notmatch 'NoSuchBucket') -and ($bucketVersionStatus -ne '[]')) {
        Write-Host "- Deleting versions"
        aws s3api delete-objects --bucket $bucket --delete $bucketVersionStatus | Out-Null
    }
    if ($bucketMarkersStatus -and ($bucketMarkersStatus -notmatch 'NoSuchBucket') -and ($bucketMarkersStatus -ne '[]')) {
        Write-Host "- Deleting markers"
        aws s3api delete-objects --bucket $bucket --delete $bucketMarkersStatus | Out-Null
    }

    aws s3api head-bucket --bucket $bucket 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "- Deleting bucket $bucket"
        aws s3 rb "s3://$bucket" --force
    } else {
        Write-Host "- Bucket $bucket not found or inaccessible" -ForegroundColor Yellow
    }
}

foreach ($bucket in $AFT_MGMT_BUCKETS) {
    Remove-BucketContentsAndDelete -bucket $bucket -region $REGION
}

# Deleting items in AFT Log Account
$env:AWS_PROFILE = 'aft-log-acct'
$AFT_LOG_BUCKETS = @(
    "aws-aft-logs-${LOG_ACCT}-${REGION}",
    "aws-aft-s3-access-logs-${LOG_ACCT}-${REGION}"
)

foreach ($bucket in $AFT_LOG_BUCKETS) {
    Remove-BucketContentsAndDelete -bucket $bucket -region $REGION
}

Write-Host "Done." -ForegroundColor Green
