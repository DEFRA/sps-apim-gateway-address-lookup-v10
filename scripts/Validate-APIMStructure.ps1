<#
 .SYNOPSIS
 Validates APIM repository structure for the new “journeys” & “environments”.
 .DESCRIPTION
 - Supports journeys: external, internal, both
 - Supports environments: base, dev, pre, tst, all
 - Enforces mandatory files at the precise subpaths you provided
 - Performs light JSON/YAML/XML content checks
 - Adds UPPER_SNAKE_CASE validation for namedValueInformation.json displayName
 - Produces GitHub Actions step summary and outputs, and non-zero exit when errors
#>

param(
 [string]$RootPath = ".",
 [ValidateSet('external','internal','both')]
 [string]$Journey = 'both',
 [ValidateSet('base','dev','pre','tst','all')]
 [string]$Environment = 'all',
 [string]$ApiName = 'address-lookup-v10',
 [string]$ProductName = 'addresslookup-product',
 [string]$VersionSetName = 'addressLookupVersionset',
 [string]$NamedValueName = 'addresslookupv10-backend-scopeid',
 [switch]$FailOnError
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Helpers
function Write-Info($m){ Write-Host "[INFO ] $m" -ForegroundColor Cyan }
function Write-Warn($m){ Write-Host "[WARN ] $m" -ForegroundColor Yellow }
function Write-Err ($m){ Write-Host "[ERROR] $m" -ForegroundColor Red }

function Resolve-File {
 param([string]$Dir, [string[]]$Candidates)
 if (-not (Test-Path -LiteralPath $Dir)) { return $null }
 $entries = Get-ChildItem -LiteralPath $Dir -File -Force
 foreach ($cand in $Candidates) {
   $hit = $entries | Where-Object { $_.Name -ieq $cand } | Select-Object -First 1
   if ($hit) { return $hit.FullName }
 }
 return $null
}

# Content validators
function Validate-NestedJsonFields {
 param($filePath, $nestedFields)
 try {
   $json = Get-Content $filePath -Raw | ConvertFrom-Json
   foreach ($field in $nestedFields) {
     switch ($field) {
       'properties.path' { if (-not $json.properties.path) { return "Missing 'properties.path' in ${filePath}" } }
       'properties.apiVersion' { if (-not $json.properties.apiVersion) { return "Missing 'properties.apiVersion' in ${filePath}" } }
       'properties.apiVersionSetId' { if (-not $json.properties.apiVersionSetId) { return "Missing 'properties.apiVersionSetId' in ${filePath}" } }
       'properties.isCurrent' { if ($null -eq $json.properties.isCurrent) { return "Missing 'properties.isCurrent' in ${filePath}" } }
       'properties.displayName' { if (-not $json.properties.displayName) { return "Missing 'properties.displayName' in ${filePath}" } }
       'properties.protocols' { if (-not $json.properties.protocols) { return "Missing 'properties.protocols' in ${filePath}" } }
       'properties.serviceUrl' { if (-not $json.properties.serviceUrl) { return "Missing 'properties.serviceUrl' in ${filePath}" } }
       'properties.subscriptionRequired' { if ($null -eq $json.properties.subscriptionRequired) { return "Missing 'properties.subscriptionRequired' in ${filePath}" } }
       'properties.secret' { if ($null -eq $json.properties.secret) { return "Missing 'properties.secret' in ${filePath}" } }
       'properties.tags' { if ($null -eq $json.properties.tags) { return "Missing 'properties.tags' in ${filePath}" } }
       'properties.value' { if (-not $json.properties.value) { return "Missing 'properties.value' in ${filePath}" } }
       'properties.description' { if (-not $json.properties.description) { return "Missing 'properties.description' in ${filePath}" } }
       'properties.state' { if (-not $json.properties.state) { return "Missing 'properties.state' in ${filePath}" } }
       'properties.versioningScheme' { if (-not $json.properties.versioningScheme) { return "Missing 'properties.versioningScheme' in ${filePath}" } }
     }
   }
 } catch {
   return "Invalid JSON format in ${filePath}"
 }
 return $null
}

function Validate-PolicyXml {
 param($filePath)
 try {
   $content = Get-Content $filePath -Raw
   if ($content -notmatch '<policies>') { return "Missing <policies> root element in ${filePath}" }
   if ($content -notmatch '<inbound>') { return "Missing <inbound> section in ${filePath}" }
 } catch {
   return "Error reading Policy.xml in ${filePath}"
 }
 return $null
}

function Validate-YamlOpenAPI {
 param($filePath)
 try {
   $content = Get-Content $filePath -Raw
   if ($content.Length -gt 0 -and $content[0] -eq [char]0xFEFF) { $content = $content.Substring(1) }
   if ($content -notmatch "(?im)^\s*(openapi|swagger)\s*:\s*['\""]?\d") { return "Missing OpenAPI/Swagger version in ${filePath}" }
   if ($content -notmatch "(?im)^\s*info\s*:") { return "Missing 'info' section in ${filePath}" }
   if ($content -notmatch "(?im)^\s*paths\s*:") { return "Missing 'paths' section in ${filePath}" }
 } catch {
   return "Invalid YAML format in ${filePath}"
 }
 return $null
}

# --- NEW VALIDATOR for UPPER_SNAKE_CASE ---
function Validate-UpperSnakeCaseDisplayName {
 param($filePath)
 try {
   $json = Get-Content $filePath -Raw | ConvertFrom-Json
   $displayName = $json.properties.displayName
   Write-Host "[INFO] Checking displayName: $displayName (File: $filePath)" -ForegroundColor White
   if (-not ($displayName -cmatch '^[A-Z0-9_]+$')) {
     return "Invalid displayName '${displayName}' in ${filePath}: Must match UPPER_SNAKE_CASE pattern ^[A-Z0-9_]+$"
   }
 } catch {
   return "Error reading ${filePath}: $_"
 }
 return $null
}

# Build target sets
$JourneyList = if ($Journey -eq 'both') { @('external','internal') } else { @($Journey) }
$EnvList = if ($Environment -eq 'all') { @('base','dev','pre','tst') } else { @($Environment) }

# Expected items
$Expectations = @(
 @{ RelDir = { param($j,$e,$n) Join-Path -Path (Join-Path (Join-Path $j $e) "apis") $n }
    Name = "apis/$ApiName"
    Required = @( @('apiInformation.json','apinformation.json'), @('Specification.yaml','specification.yaml','specification.yml'), @('Policy.xml','policy.xml') )
    Validators = @{
      'apiInformation.json\napinformation.json' = { param($p) Validate-NestedJsonFields $p @('properties.path','properties.apiVersion','properties.apiVersionSetId','properties.isCurrent','properties.displayName','properties.protocols','properties.serviceUrl','properties.subscriptionRequired') }
      'Specification.yaml\nspecification.yaml\nspecification.yml' = { param($p) Validate-YamlOpenAPI $p }
      'Policy.xml\npolicy.xml' = { param($p) Validate-PolicyXml $p }
    }
 },
 @{ RelDir = { param($j,$e,$n) Join-Path -Path (Join-Path (Join-Path $j $e) "products") $n }
    Name = "products/$ProductName"
    Required = @( @('productInformation.json') )
    Validators = @{
      'productInformation.json' = { param($p) Validate-NestedJsonFields $p @('properties.displayName','properties.description','properties.state') }
    }
 },
 @{ RelDir = { param($j,$e,$n) Join-Path -Path (Join-Path (Join-Path (Join-Path $j $e) "products") $ProductName) (Join-Path 'apis' $ApiName) }
    Name = "products/$ProductName/apis/$ApiName"
    Required = @( @('productApiInformation.json') )
    Validators = @{}
 },
 @{ RelDir = { param($j,$e,$n) Join-Path -Path (Join-Path (Join-Path $j $e) "version sets") $n }
    Name = "version sets/$VersionSetName"
    Required = @( @('versionSetInformation.json') )
    Validators = @{
      'versionSetInformation.json' = { param($p) Validate-NestedJsonFields $p @('properties.displayName','properties.versioningScheme') }
    }
 },
 @{ RelDir = { param($j,$e,$n) Join-Path -Path (Join-Path (Join-Path $j $e) "named values") $n }
    Name = "named values/$NamedValueName"
    Required = @( @('namedValueInformation.json') )
    Validators = @{
      'namedValueInformation.json' = { param($p)
        $r = Validate-NestedJsonFields $p @('properties.displayName','properties.secret','properties.tags','properties.value')
        if ($r) { return $r }
        return Validate-UpperSnakeCaseDisplayName $p
      }
    }
 }
)

# Run validation
$Errors = @()
$SummaryLines = @()
foreach ($journey in $JourneyList) {
 foreach ($env in $EnvList) {
   $envPath = Join-Path $RootPath (Join-Path $journey $env)
   if (-not (Test-Path $envPath)) {
     $Errors += "Missing environment folder: ${envPath}"
     $SummaryLines += "$journey | $env | (folder) | ❌ Missing environment folder"
     continue
   }
   foreach ($exp in $Expectations) {
     $dir = & $exp.RelDir $journey $env $( if ($exp.Name -like 'apis/*') { $ApiName } elseif ($exp.Name -like 'products/*') { $ProductName } elseif ($exp.Name -like 'version*') { $VersionSetName } else { $NamedValueName } )
     if (-not (Test-Path $dir)) {
       $Errors += "Missing folder: ${dir}"
       $SummaryLines += "$journey | $env | $($exp.Name) | ❌ Missing folder"
       continue
     }
     foreach ($group in $exp.Required) {
       $resolved = Resolve-File -Dir $dir -Candidates $group
       if (-not $resolved) {
         $Errors += "Missing file in '${dir}': one of [$(($group -join ', '))]"
         $SummaryLines += "$journey | $env | $($exp.Name) | ❌ Missing $(($group -join ' / '))"
       } else {
         $leaf = (Split-Path $resolved -Leaf)
         $SummaryLines += "$journey | $env | $($exp.Name) | ✅ $leaf"
         foreach ($key in $exp.Validators.Keys) {
           $alts = $key -split '\n'
           if ($alts -contains $leaf) {
             $r = & $exp.Validators[$key] $resolved
             if ($r) {
               $Errors += $r
               $SummaryLines += "$journey | $env | $($exp.Name) | ❌ $r"
             }
           }
         }
       }
     }
   }
 }
}

# Output summary
$EOL = "`r`n"
$header = @"
## 🔍 APIM Validation Summary
Journeys: $(($JourneyList -join ', '))
Environments: $(($EnvList -join ', '))
Journey | Env | Item | Status
--- | --- | --- | ---
"@
$body = ($SummaryLines -join $EOL)
if ($Errors.Count -gt 0) {
 $status = "❌ Validation FAILED. $($Errors.Count) issue(s) found."
 $footer = "### Issues:$EOL" + ($Errors -join $EOL)
 $exit = 1
} else {
 $status = "✅ Validation PASSED. All checks successful."
 $footer = ""
 $exit = 0
}
$full = $header + $EOL + $body + $EOL + $EOL + $status + $EOL + $footer + $EOL
if ($env:GITHUB_STEP_SUMMARY) {
 $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
 [System.IO.File]::WriteAllText($env:GITHUB_STEP_SUMMARY, $full, $utf8NoBom)
} else {
 Write-Host "`n--- Summary (Local Preview) ---`n$full"
}
if ($env:GITHUB_OUTPUT) {
 "result=$status" | Out-File -FilePath $env:GITHUB_OUTPUT -Encoding utf8 -Append
 "exit_code=$exit" | Out-File -FilePath $env:GITHUB_OUTPUT -Encoding utf8 -Append
}
if ($FailOnError -and $exit -ne 0) { exit $exit }
