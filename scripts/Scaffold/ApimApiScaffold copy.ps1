
<#
.SYNOPSIS
 APIM Self‑Serve scaffolding tool (PS 5.1/7 compatible) with diagnostics

.DESCRIPTION
 - Generates APIM self‑serve folder structure under OutRoot[/Environment]
 - Applies per‑environment overrides in input JSON
 - Token replacement for ALL template types (JSON/YAML/XML):
     * ONLY double‑angle tokens: <<TOKEN>>   (single‑angle <TOKEN> is ignored)
     * {{brace}} tokens resolved via script token bag (based on aliases/inputs)
 - JSON templates (apiInformation.json, productInformation.json, versionSetInformation.json)
   are tokenized as text, then parsed, then patched via mapping JSONPaths
 - Supports API_NAME‑specific template folders under TemplatesRoot (e.g., apis/API_NAME)
 - Emits JSON + Markdown audit reports + optional diagnostics log/samples

 Exit codes:
  0 = success
  1 = validation errors
  2 = substitution errors
  3 = filesystem/path errors
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)] [string] $InputJson,
  [Parameter(Mandatory=$true)] [string] $Schema,
  [Parameter(Mandatory=$true)] [string] $Mapping,
  [Parameter(Mandatory=$true)] [string] $TemplatesRoot,
  [Parameter(Mandatory=$false)] [string] $OutRoot = (Get-Location).Path,
  [Parameter(Mandatory=$false)] [string] $Environment, # dev|tst|pre|prod
  [Parameter(Mandatory=$false)] [string] $SpecPath,     # team-provided OpenAPI spec (optional)
  [Parameter(Mandatory=$false)] [switch] $DryRun,
  [Parameter(Mandatory=$false)] [switch] $Overwrite,
  [Parameter(Mandatory=$false)] [switch] $AllowMissing,
  [Parameter(Mandatory=$false)] [switch] $RenameTemplateFolders, # copy/rename templates/.../API_NAME/* → templates/.../<api>/*

  # --- Diagnostics ---
  [Parameter(Mandatory=$false)] [switch] $Diagnostics,     # enable verbose diagnostics
  [Parameter(Mandatory=$false)] [int]    $DiagDumpChars = 160, # how many chars to show in samples
  [Parameter(Mandatory=$false)] [switch] $DiagSaveSamples  # save pre/post samples under reports/samples
)

# -----------------------------------------------------------------------------
# Runtime and audit
# -----------------------------------------------------------------------------
$ErrorActionPreference = 'Stop'
$CorrelationId = [guid]::NewGuid().ToString()
$Timestamp = (Get-Date).ToString('o')
$ExitCodeFS = $null
$SubError = $false

# Prepare diagnostics log early
$diagDir = Join-Path $OutRoot "reports"
if(-not (Test-Path -LiteralPath $diagDir)){ New-Item -ItemType Directory -Path $diagDir -Force | Out-Null }
$diagLog = Join-Path $diagDir ("diag-" + $CorrelationId + ".log")
"" | Set-Content -LiteralPath $diagLog

function Write-Diag([string]$m){
  if($Diagnostics.IsPresent){
    $line = "[DIAG] " + $m
    Write-Host $line -ForegroundColor DarkGray
    Add-Content -LiteralPath $diagLog -Value ("{0:o} {1}" -f (Get-Date), $line)
  }
}

$audit = [ordered]@{
  correlationId = $CorrelationId
  timestamp     = $Timestamp
  inputJson     = $InputJson
  schema        = $Schema
  mapping       = $Mapping
  templatesRoot = $TemplatesRoot
  outRoot       = $OutRoot
  environment   = $Environment
  specPath      = $SpecPath
  dryRun        = [bool]$DryRun
  overwrite     = [bool]$Overwrite
  allowMissing  = [bool]$AllowMissing
  renameTemplateFolders= [bool]$RenameTemplateFolders
  diagnostics   = [bool]$Diagnostics
  diagDumpChars = [int]$DiagDumpChars
  diagSaveSamples= [bool]$DiagSaveSamples
  schemaVersion = $null
  plan          = @{ folders = @(); files = @() }
  filesCreated  = @()
  filesUpdated  = @()
  filesSkipped  = @()
  substitutions = @{ success = @(); missing = @(); warnings = @() }
  errors        = @()
}

# -----------------------------------------------------------------------------
# Logging helpers
# -----------------------------------------------------------------------------
function Write-Info($m){ Write-Host "[INFO] $m" -ForegroundColor Cyan }
function Write-Warn($m){ Write-Warning "[WARN] $m"; $audit.substitutions.warnings += $m }
function Write-Err ($m){ Write-Error   "[ERROR] $m"; $audit.errors               += $m }

Write-Diag "PSVersion: $($PSVersionTable.PSVersion); OS: $([System.Environment]::OSVersion.VersionString)"
Write-Diag "CorrelationId: $CorrelationId"

# -----------------------------------------------------------------------------
# IO helpers
# -----------------------------------------------------------------------------
function Resolve-PathSafe([string]$p){
  if(Test-Path -LiteralPath $p){ return (Resolve-Path -LiteralPath $p).Path }
  $alt = Join-Path $PSScriptRoot $p
  if(Test-Path -LiteralPath $alt){ return (Resolve-Path -LiteralPath $alt).Path }
  throw "Path not found: $p"
}
function Get-Json([string]$p){
  (Get-Content -LiteralPath $p -Raw) | ConvertFrom-Json
}
function Save-Json([object]$obj, [string]$p){
  $json = $obj | ConvertTo-Json -Depth 50
  $dir = Split-Path -Parent $p
  if(-not (Test-Path -LiteralPath $dir)){ New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  Set-Content -LiteralPath $p -Value $json -NoNewline
}
function Save-Text([string]$text, [string]$p){
  $dir = Split-Path -Parent $p
  if(-not (Test-Path -LiteralPath $dir)){ New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  Set-Content -LiteralPath $p -Value $text
}
function Ensure-Dir([string]$p){
  if(Test-Path -LiteralPath $p){ return $true }
  if($DryRun.IsPresent){ return $false }
  New-Item -ItemType Directory -Path $p -Force | Out-Null
  return $true
}
function Make-BackupPath([string]$targetPath){
  $safeTs = $Timestamp.Replace(':','-')
  $bakRoot = Join-Path $OutRoot ".bak/$safeTs"
  $rel = $targetPath
  try {
    $relCandidate = Resolve-Path -LiteralPath $targetPath -Relative
    if($relCandidate){ $rel = $relCandidate }
  } catch {
    if ($targetPath.StartsWith($OutRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
      $rel = $targetPath.Substring($OutRoot.Length).TrimStart('\','/')
    } else {
      $rel = Split-Path -Leaf $targetPath
    }
  }
  $dest = Join-Path $bakRoot $rel
  $destDir = Split-Path -Parent $dest
  if(-not (Test-Path -LiteralPath $destDir)){ New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
  return $dest
}
function Backup-IfExists([string]$p){
  if(Test-Path -LiteralPath $p){
    $bak = Make-BackupPath $p
    Copy-Item -LiteralPath $p -Destination $bak -Force
    return $bak
  }
  return $null
}

# -----------------------------------------------------------------------------
# Minimal schema validator (required/pattern/uri)
# -----------------------------------------------------------------------------
function Validate-AgainstSchema([pscustomobject]$data, [pscustomobject]$schemaObj){
  $errs = @()
  if($schemaObj.PSObject.Properties.Name -contains 'version'){ $audit.schemaVersion = $schemaObj.version }
  elseif ($schemaObj.PSObject.Properties.Name -contains 'title'){ $audit.schemaVersion = $schemaObj.title }
  if($schemaObj.required){
    foreach($req in $schemaObj.required){
      if(-not ($data.PSObject.Properties.Name -contains $req)){
        $errs += "Missing required field: $req"
      } elseif ([string]::IsNullOrWhiteSpace([string]$data.$req)){
        $errs += "Empty value for required field: $req"
      }
    }
  }
  if($schemaObj.properties){
    foreach($prop in $schemaObj.properties.PSObject.Properties){
      $name = $prop.Name
      $def = $prop.Value
      if(-not ($data.PSObject.Properties.Name -contains $name)){ continue }
      $value = [string]$data.$name
      if($def.pattern){ if(-not ($value -match $def.pattern)){ $errs += "Field '$name' fails pattern '$($def.pattern)' → '$value'" } }
      if($def.format -eq 'uri'){
        if(-not [Uri]::IsWellFormedUriString($value,[UriKind]::Absolute)){ $errs += "Field '$name' invalid absolute URI → '$value'" }
      }
    }
  }
  if($data.PSObject.Properties.Name -contains 'environments' -and $schemaObj.$defs.envOverrides){
    foreach($env in $data.environments.PSObject.Properties){
      $envObj = $env.Value
      foreach($p in $envObj.PSObject.Properties){
        $nm = $p.Name; $val = [string]$p.Value
        $def = $schemaObj.$defs.envOverrides.properties.$nm
        if($def){
          if($def.format -eq 'uri' -and (-not [Uri]::IsWellFormedUriString($val,[UriKind]::Absolute))){ $errs += "Env '$($env.Name)' field '$nm' invalid URI → '$val'" }
          if($def.pattern -and (-not ($val -match $def.pattern))){ $errs += "Env '$($env.Name)' field '$nm' fails pattern '$($def.pattern)' → '$val'" }
        }
      }
    }
  }
  return $errs
}

# -----------------------------------------------------------------------------
# JSONPath setter (simple $.a.b.c)
# -----------------------------------------------------------------------------
function Set-JsonPathValue([object]$obj, [string]$jsonPath, [object]$value){
  if(-not $jsonPath.StartsWith('$.')){ throw "Unsupported JSONPath: $jsonPath" }
  $parts  = $jsonPath.TrimStart('$.').Split('.')
  $cursor = $obj
  for($i=0; $i -lt ($parts.Length-1); $i++){
    $p = $parts[$i]
    if(-not ($cursor.PSObject.Properties.Name -contains $p)){
      $cursor | Add-Member -MemberType NoteProperty -Name $p -Value ([PSCustomObject]@{})
    }
    $cursor = $cursor.$p
  }
  $leaf = $parts[-1]
  if($cursor.PSObject.Properties.Name -contains $leaf){ $cursor.$leaf = $value }
  else { $cursor | Add-Member -MemberType NoteProperty -Name $leaf -Value $value }
}

# -----------------------------------------------------------------------------
# Diagnostics helpers (token detection & samples)
# -----------------------------------------------------------------------------
function Normalize-EncodedText([string]$text){
  # HTML entities
  $t = [System.Net.WebUtility]::HtmlDecode($text)
  # JSON unicode escapes for < > &
  $t = $t -replace '\\u003c','<' -replace '\\u003e','>' -replace '\\u0026','&'
  # Any residual entities (double-encoded)
  $t = $t -replace '&lt;','<' -replace '&gt;','>' -replace '&amp;','&'
  return $t
}

function Detect-Tokens([string]$text){
  $reDouble = '<<\s*([A-Za-z0-9_]+)\s*>>'
  $reBrace  = '\{\{\s*([A-Za-z0-9_\-]+)\s*\}\}'

  $d = [ordered]@{}
  $d.double = ([regex]::Matches($text, $reDouble) | ForEach-Object { $_.Groups[1].Value.ToUpper() }) | Select-Object -Unique
  $d.brace  = ([regex]::Matches($text, $reBrace)  | ForEach-Object { $_.Groups[1].Value.ToLower() }) | Select-Object -Unique
  return [pscustomobject]$d
}

function Dump-Sample([string]$label, [string]$text, [int]$n){
  $snippet = $text.Substring(0, [Math]::Min($n, $text.Length)).Replace("`r"," ").Replace("`n"," ")
  Write-Diag "$label sample($n): $snippet"
  return $snippet
}

function Save-SampleFile([string]$label, [string]$stage, [string]$text, [int]$n){
  if(-not $DiagSaveSamples.IsPresent){ return }
  $samplesDir = Join-Path $diagDir "samples"
  if(-not (Test-Path -LiteralPath $samplesDir)){ New-Item -ItemType Directory -Path $samplesDir -Force | Out-Null }
  $file = Join-Path $samplesDir ("{0}-{1}-{2}.txt" -f ($label -replace '[^\w\-]','_'), $stage, $CorrelationId)
  $snippet = $text.Substring(0, [Math]::Min($n, $text.Length))
  Set-Content -LiteralPath $file -Value $snippet
  Write-Diag "Saved sample: $file"
}

# -----------------------------------------------------------------------------
# Token replacement (DOUBLE-ANGLE + BRACE) — reusable for ALL templates
# -----------------------------------------------------------------------------
function Replace-Tokens(
  [string] $Text,
  [pscustomobject] $InputObj,
  [hashtable] $BraceTokens,
  [pscustomobject] $Mapping,
  [bool] $AllowMissing
){
  # --- 1) Normalize encodings ---
  $Text = Normalize-EncodedText $Text

  # Canonicalize encoded double-angle token shapes (just in case they survived)
  $Text = [regex]::Replace($Text, '&lt;&lt;\s*([A-Za-z0-9_]+)\s*&gt;&gt;', { '<<' + $args[0].Groups[1].Value.ToUpper() + '>>' })
  $Text = [regex]::Replace($Text, '\\u003c\\u003c\s*([A-Za-z0-9_]+)\s*\\u003e\\u003e', { '<<' + $args[0].Groups[1].Value.ToUpper() + '>>' })

  # --- 2) Discover tokens present in normalized text (DOUBLE ONLY) ---
  $reDouble = '<<\s*([A-Za-z0-9_]+)\s*>>'
  $reBrace  = '\{\{\s*([A-Za-z0-9_\-]+)\s*\}\}'

  $presentDouble = ([regex]::Matches($Text, $reDouble) | ForEach-Object { $_.Groups[1].Value.ToUpper() }) | Select-Object -Unique

  if($Diagnostics.IsPresent){
    Write-Diag ("Replace-Tokens: present double-angle = " + ($presentDouble -join ', '))
    $presentBrace = ([regex]::Matches($Text, $reBrace) | ForEach-Object { $_.Groups[1].Value.ToLower() }) | Select-Object -Unique
    Write-Diag ("Replace-Tokens: present brace       = " + ($presentBrace -join ', '))
  }

  # --- 3) Resolve and replace DOUBLE-ANGLE deterministically ---
  function Resolve-AngleValue([string]$NAME, [pscustomobject]$InputObj, [pscustomobject]$Mapping){
    if($InputObj.PSObject.Properties.Name -contains $NAME){ return [string]$InputObj.$NAME }
    if($Mapping -and ($Mapping.PSObject.Properties.Name -contains 'angleAliases')){
      if($Mapping.angleAliases.PSObject.Properties.Name -contains $NAME){
        $key = [string]$Mapping.angleAliases.$NAME
        if($InputObj.PSObject.Properties.Name -contains $key){ return [string]$InputObj.$key }
      }
    }
    return $null
  }

  $missingDouble = @()
  foreach($NAME in $presentDouble){
    $val = Resolve-AngleValue $NAME $InputObj $Mapping
    if([string]::IsNullOrWhiteSpace($val)){
      $missingDouble += $NAME
      continue
    }
    # Replace canonical and whitespace variants
    $Text = $Text.Replace("<<$NAME>>", $val)
    $Text = [regex]::Replace($Text, ("<<\s*{0}\s*>>" -f [regex]::Escape($NAME)), [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $val })

    if($Diagnostics.IsPresent){ Write-Diag ("ANGLE: {0} -> '{1}'" -f $NAME, $val) }
  }

  # --- 4) Deterministic replacement for BRACE tokens ---
  foreach($k in $BraceTokens.Keys){
    $pattern = '(?i)\{\{\s*' + [regex]::Escape($k) + '\s*\}\}'
    $Text = [regex]::Replace($Text, $pattern, [string]$BraceTokens[$k])
    if($Diagnostics.IsPresent){ Write-Diag ("BRACE: {0} -> '{1}'" -f $k, $BraceTokens[$k]) }
  }

  # --- 5) Final unresolved check (DOUBLE + BRACE only) ---
  $unresolved = @()
  $unresolved += ([regex]::Matches($Text, $reDouble) | ForEach-Object { $_.Value })
  $unresolved += ([regex]::Matches($Text, $reBrace)  | ForEach-Object { $_.Value })
  $unresolved = $unresolved | Select-Object -Unique

  if( ($unresolved.Count -gt 0) -and (-not $AllowMissing) ){
    if($Diagnostics.IsPresent -and $missingDouble.Count -gt 0){
      Write-Diag ("Unresolved DOUBLE-ANGLE tokens (no value found): " + ($missingDouble -join ', '))
    }
    throw ("Unresolved placeholders remain in template content: " + ($unresolved -join ', '))
  }
  return $Text
}

# -----------------------------------------------------------------------------
# Diagnostic-aware template loaders
# -----------------------------------------------------------------------------
function Load-TemplateText-WithTokens(
  [string] $templatePath,
  [pscustomobject] $effectiveObj,
  [hashtable] $braceTokens,
  [pscustomobject] $mappingObj,
  [switch] $AllowMissing,
  [string] $label = "template"
){
  if (-not (Test-Path -LiteralPath $templatePath)) {
    throw "Template not found: $templatePath"
  }
  Write-Diag "$label path: $templatePath"
  $raw = Get-Content -LiteralPath $templatePath -Raw
  Dump-Sample "$label raw" $raw $DiagDumpChars | Out-Null
  Save-SampleFile $label "raw" $raw $DiagDumpChars

  $norm = Normalize-EncodedText $raw
  Dump-Sample "$label normalized" $norm $DiagDumpChars | Out-Null
  Save-SampleFile $label "normalized" $norm $DiagDumpChars

  $pre = Detect-Tokens $norm
  Write-Diag "$label tokens (pre): << >> = $($pre.double.Count), {{ }} = $($pre.brace.Count)"
  if($pre.double.Count -gt 0){ Write-Diag "$label tokens (pre, double): $([string]::Join(', ', ($pre.double)))" }
  if($pre.brace.Count  -gt 0){ Write-Diag "$label tokens (pre, brace):  $([string]::Join(', ', ($pre.brace)))" }

  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  # IMPORTANT: pass normalized text to Replace-Tokens
  $text = Replace-Tokens `
    -Text $norm `
    -InputObj $effectiveObj `
    -BraceTokens $braceTokens `
    -Mapping $mappingObj `
    -AllowMissing ([bool]$AllowMissing)
  $sw.Stop()
  Write-Diag "$label replacement time: $($sw.ElapsedMilliseconds) ms"

  Dump-Sample "$label replaced" $text $DiagDumpChars | Out-Null
  Save-SampleFile $label "replaced" $text $DiagDumpChars

  $post = Detect-Tokens $text
  Write-Diag "$label tokens (post): << >> = $($post.double.Count), {{ }} = $($post.brace.Count)"
  if(($post.double.Count + $post.brace.Count) -gt 0){
    Write-Diag "$label tokens (post, unresolved): double=[$([string]::Join(', ', ($post.double)))] ; brace=[$([string]::Join(', ', ($post.brace)))]"
  }

  return $text
}

function Load-TemplateJson-WithTokens(
  [string] $templatePath,
  [pscustomobject] $effectiveObj,
  [hashtable] $braceTokens,
  [pscustomobject] $mappingObj,
  [switch] $AllowMissing,
  [string] $label = "template.json"
){
  $text = Load-TemplateText-WithTokens -templatePath $templatePath -effectiveObj $effectiveObj -braceTokens $braceTokens -mappingObj $mappingObj -AllowMissing:$AllowMissing -label:$label
  try {
    $obj = $text | ConvertFrom-Json
  } catch {
    throw "Template '$templatePath' could not be parsed as JSON after token replacement. Error: $($_.Exception.Message)"
  }
  return $obj
}

# -----------------------------------------------------------------------------
# Load and validate inputs
# -----------------------------------------------------------------------------
try{
  $InputJson    = Resolve-PathSafe $InputJson
  $Schema       = Resolve-PathSafe $Schema
  $Mapping      = Resolve-PathSafe $Mapping
  $TemplatesRoot= Resolve-PathSafe $TemplatesRoot
  if($SpecPath){ $SpecPath = Resolve-PathSafe $SpecPath }

  Write-Info "[PATH] InputJson     = $InputJson"
  Write-Info "[PATH] Schema        = $Schema"
  Write-Info "[PATH] Mapping       = $Mapping"
  Write-Info "[PATH] TemplatesRoot = $TemplatesRoot"
  if($SpecPath){ Write-Info "[PATH] SpecPath = $SpecPath" }

  $inputObj   = Get-Json $InputJson
  $schemaObj  = Get-Json $Schema
  $mappingObj = Get-Json $Mapping
} catch {
  Write-Err "Failed to resolve/load paths: $($_.Exception.Message)"
  exit 3
}
$valErrors = Validate-AgainstSchema $inputObj $schemaObj
if($valErrors.Count -gt 0){
  foreach($e in $valErrors){ Write-Err $e }
  Write-Err "JSON validation errors encountered."
  exit 1
}

# -----------------------------------------------------------------------------
# Resolve environment overlay
# -----------------------------------------------------------------------------
$effective = @{}
foreach($p in $inputObj.PSObject.Properties){
  if($p.Name -ne 'environments'){ $effective[$p.Name] = $p.Value }
}
if($Environment -and $inputObj.PSObject.Properties.Name -contains 'environments'){
  $envKey = $Environment.ToLower()
  $envObj = $inputObj.environments.$envKey
  if($envObj){
    foreach($p in $envObj.PSObject.Properties){ $effective[$p.Name] = $p.Value }
  } else {
    Write-Warn "Environment '$Environment' not found; using base values."
  }
}
$effectiveObj = [pscustomobject]$effective
if(-not ($effectiveObj.PSObject.Properties.Name -contains 'API_NAME')){
  Write-Err "API_NAME missing from input JSON after overlay"
  exit 1
}
$apiName = [string]$effectiveObj.API_NAME
$baseRoot = if([string]::IsNullOrWhiteSpace($Environment)) { $OutRoot } else { Join-Path $OutRoot $Environment }

Write-Diag "Effective keys: $([string]::Join(', ', ( $effectiveObj.PSObject.Properties.Name | Sort-Object )))"

# -----------------------------------------------------------------------------
# Folder paths (contract)
# -----------------------------------------------------------------------------
$apisRoot        = Join-Path $baseRoot 'apis'
$productsRoot    = Join-Path $baseRoot 'products'
$versionSetsRoot = Join-Path $baseRoot 'version sets'
$namedValuesRoot = Join-Path $baseRoot 'namedValues'

$apiFolder        = Join-Path $apisRoot        $apiName
$productFolder    = Join-Path $productsRoot    "${apiName}_product"
$versionSetFolder = Join-Path $versionSetsRoot $apiName
$nvBackendFolder  = Join-Path $namedValuesRoot "${apiName}-backend-scopeid"
$nvFrontendFolder = Join-Path $namedValuesRoot "consuming-frontend-clientid"

$audit.plan.folders = @($apisRoot,$productsRoot,$versionSetsRoot,$namedValuesRoot,
                        $apiFolder,$productFolder,$versionSetFolder,$nvBackendFolder,$nvFrontendFolder)

foreach($dir in $audit.plan.folders){
  if(Test-Path -LiteralPath $dir){
    Write-Info "Folder exists: $dir"; $audit.filesSkipped += "Folder exists: $dir"
  } else {
    if($DryRun.IsPresent){ Write-Info "Plan to create folder: $dir" }
    else {
      try{ Ensure-Dir $dir | Out-Null; $audit.filesCreated += "Folder created: $dir"; Write-Info "Created $dir" }
      catch{ Write-Err "Failed to create '$dir': $($_.Exception.Message)"; $ExitCodeFS = 3 }
    }
  }
}
if($ExitCodeFS -eq 3){ Write-Err "Filesystem errors encountered."; exit 3 }

# -----------------------------------------------------------------------------
# Template path resolver (API_NAME-aware)
# -----------------------------------------------------------------------------
function Tpl([string]$logical){
  if(-not $mappingObj.templates.$logical){ throw "Template mapping missing for '$logical' in mapping.json" }
  $rel = [string]$mappingObj.templates.$logical
  $relReplaced = $rel -replace 'API_NAME',$apiName
  $fullReplaced= Join-Path $TemplatesRoot $relReplaced
  $fullLiteral = Join-Path $TemplatesRoot $rel
  if(Test-Path -LiteralPath $fullReplaced){ return $fullReplaced }
  elseif(Test-Path -LiteralPath $fullLiteral){ return $fullLiteral }
  else{ throw "Template '$logical' not found at '$fullReplaced' or '$fullLiteral'" }
}

# -----------------------------------------------------------------------------
# Materialize API_NAME template folders (COPY/RENAME) — PS 5.1 safe
# -----------------------------------------------------------------------------
foreach($tplProp in $mappingObj.templates.PSObject.Properties){
  $rel = [string]$tplProp.Value
  if($rel -match 'API_NAME'){
    $src = Join-Path $TemplatesRoot (Split-Path $rel -Parent)
    $dst = Join-Path $TemplatesRoot (Split-Path ($rel -replace 'API_NAME',$apiName) -Parent)
    if((Test-Path -LiteralPath $src) -and -not (Test-Path -LiteralPath $dst)){
      $action = 'COPY'
      if ($RenameTemplateFolders.IsPresent) { $action = 'RENAME' }
      if($DryRun.IsPresent){
        Write-Info "Plan to $action '$src' → '$dst'"
      }
      else{
        try{
          if($RenameTemplateFolders.IsPresent){ Move-Item -LiteralPath $src -Destination $dst -Force }
          else { Copy-Item -LiteralPath $src -Destination $dst -Recurse -Force }
          Write-Info "Template folder materialized: $dst"
        } catch {
          Write-Err "Failed to materialize template folder '$src' → '$dst': $($_.Exception.Message)"; $ExitCodeFS = 3
        }
      }
    }
  }
}
if($ExitCodeFS -eq 3){ Write-Err "Filesystem errors encountered."; exit 3 }

# -----------------------------------------------------------------------------
# Destination files
# -----------------------------------------------------------------------------
$dstApiInfo      = Join-Path $apiFolder      'apiInformation.json'
$dstPolicy       = Join-Path $apiFolder      'policy.xml'
$dstSpec         = Join-Path $apiFolder      'specification.yaml'
$dstProductInfo  = Join-Path $productFolder  'productInformation.json'
$dstVersionInfo  = Join-Path $versionSetFolder 'versionSetInformation.json'
$audit.plan.files = @($dstApiInfo,$dstPolicy,$dstSpec,$dstProductInfo,$dstVersionInfo)

# -----------------------------------------------------------------------------
# Brace token bag (policy + JSON/YAML templates)
# -----------------------------------------------------------------------------
$tokens = @{}
if($effectiveObj.PSObject.Properties.Name -contains 'TENANT_ID')                         { $tokens['tenant_id']          = [string]$effectiveObj.TENANT_ID }
if($effectiveObj.PSObject.Properties.Name -contains 'API_BACKEND_SCOPEID_VALUE')         { $tokens['backend_scopeid']    = [string]$effectiveObj.API_BACKEND_SCOPEID_VALUE }
if($effectiveObj.PSObject.Properties.Name -contains 'CONSUMING_FRONTEND_CLIENTID_VALUE') { $tokens['frontend_clientid']  = [string]$effectiveObj.CONSUMING_FRONTEND_CLIENTID_VALUE }
if($effectiveObj.PSObject.Properties.Name -contains 'RATE_LIMIT_CALLS')                  { $tokens['rate_limit_calls']   = [string]$effectiveObj.RATE_LIMIT_CALLS }
if($effectiveObj.PSObject.Properties.Name -contains 'RATE_LIMIT_PERIOD')                 { $tokens['rate_limit_period']  = [string]$effectiveObj.RATE_LIMIT_PERIOD }
foreach($k in @('API_NAME','API_VERSION','API_DISPLAY_NAME','API_DESCRIPTION','API_BACKEND_URL')){
  if($effectiveObj.PSObject.Properties.Name -contains $k){ $tokens[$k.ToLower()] = [string]$effectiveObj.$k }
}
Write-Diag ("Brace token keys available: {0}" -f ([string]::Join(', ', ( $tokens.Keys | Sort-Object ))))

# -----------------------------------------------------------------------------
# Overwrite/backup helper
# -----------------------------------------------------------------------------
function Handle-OverwriteAndBackup([string]$p){
  if(Test-Path -LiteralPath $p){
    if($Overwrite.IsPresent){
      $bak = Backup-IfExists $p
      if($bak){ Write-Info "Backed up '$p' → '$bak'"; $audit.filesUpdated += $p }
      return $true
    } else {
      Write-Warn "File exists; overwrite=false. Skipping: $p"; $audit.filesSkipped += $p
      return $false
    }
  }
  return $true
}

# -----------------------------------------------------------------------------
# apiInformation.json (tokenize JSON template, then JSONPath patches)
# -----------------------------------------------------------------------------
try{
  $tplApiInfo = Tpl 'apiInformation.json'
  if(Handle-OverwriteAndBackup $dstApiInfo){
    $apiInfoObj = if(Test-Path -LiteralPath $tplApiInfo){
      Load-TemplateJson-WithTokens -templatePath $tplApiInfo -effectiveObj $effectiveObj -braceTokens $tokens -mappingObj $mappingObj -AllowMissing:$AllowMissing -label "apiInformation.json"
    } else { [PSCustomObject]@{} }

    foreach($f in $mappingObj.fields){
      foreach($u in $f.usage){
        if(($u.target -eq 'file') -and ($u.file -eq 'apiInformation.json') -and $u.jsonPath){
          $key  = $f.inputKey; $path = $u.jsonPath
          if($effectiveObj.PSObject.Properties.Name -contains $key){
            Set-JsonPathValue -obj $apiInfoObj -jsonPath $path -value $effectiveObj.$key
            $audit.substitutions.success += "apiInformation.json: $path ← $key"
          } elseif($f.mandatory -and (-not $AllowMissing.IsPresent)){
            $audit.substitutions.missing += "apiInformation.json: $path ← $key (missing)"; $SubError = $true
          } else { Write-Warn "Missing optional field '$key' for $path" }
        }
      }
    }

    if($DryRun.IsPresent){ Write-Info "Plan to write $dstApiInfo" }
    else{ Save-Json $apiInfoObj $dstApiInfo; $audit.filesCreated += $dstApiInfo }
  }
} catch {
  Write-Err "apiInformation.json failure: $($_.Exception.Message)"; $SubError = $true
}

# -----------------------------------------------------------------------------
# productInformation.json (tokenize JSON template, then JSONPath patches)
# -----------------------------------------------------------------------------
try{
  $tplProductInfo = Tpl 'productInformation.json'
  if(Handle-OverwriteAndBackup $dstProductInfo){
    $productObj = if(Test-Path -LiteralPath $tplProductInfo){
      Load-TemplateJson-WithTokens -templatePath $tplProductInfo -effectiveObj $effectiveObj -braceTokens $tokens -mappingObj $mappingObj -AllowMissing:$AllowMissing -label "productInformation.json"
    } else { [PSCustomObject]@{} }

    foreach($f in $mappingObj.fields){
      foreach($u in $f.usage){
        if(($u.target -eq 'file') -and ($u.file -eq 'productInformation.json') -and $u.jsonPath){
          $key  = $f.inputKey; $path = $u.jsonPath
          if($effectiveObj.PSObject.Properties.Name -contains $key){
            Set-JsonPathValue -obj $productObj -jsonPath $path -value $effectiveObj.$key
            $audit.substitutions.success += "productInformation.json: $path ← $key"
          } elseif($f.mandatory -and (-not $AllowMissing.IsPresent)){
            $audit.substitutions.missing += "productInformation.json: $path ← $key (missing)"; $SubError = $true
          } else { Write-Warn "Missing optional field '$key' for $path" }
        }
      }
    }

    if($DryRun.IsPresent){ Write-Info "Plan to write $dstProductInfo" }
    else{ Save-Json $productObj $dstProductInfo; $audit.filesCreated += $dstProductInfo }
  }
} catch {
  Write-Err "productInformation.json failure: $($_.Exception.Message)"; $SubError = $true
}

# -----------------------------------------------------------------------------
# versionSetInformation.json (tokenize JSON template, then post defaults + mapping JSONPaths)
# -----------------------------------------------------------------------------
try{
  $tplVersionInfo = Tpl 'versionSetInformation.json'
  if(Handle-OverwriteAndBackup $dstVersionInfo){
    $vsObj = if (Test-Path -LiteralPath $tplVersionInfo) {
      Load-TemplateJson-WithTokens -templatePath $tplVersionInfo -effectiveObj $effectiveObj -braceTokens $tokens -mappingObj $mappingObj -AllowMissing:$AllowMissing -label "versionSetInformation.json"
    } else { [PSCustomObject]@{} }

    if(-not ($vsObj.PSObject.Properties.Name -contains 'properties')){
      $vsObj | Add-Member -MemberType NoteProperty -Name properties -Value ([PSCustomObject]@{})
    }
    if(-not ($vsObj.properties.PSObject.Properties.Name -contains 'displayName')){
      $vsObj.properties | Add-Member -MemberType NoteProperty -Name displayName -Value "$apiName API"
    }
    if(-not ($vsObj.properties.PSObject.Properties.Name -contains 'versioningScheme')){
      $vsObj.properties | Add-Member -MemberType NoteProperty -Name versioningScheme -Value 'Segment'
    }

    foreach($f in $mappingObj.fields){
      foreach($u in $f.usage){
        if(($u.target -eq 'file') -and ($u.file -eq 'versionSetInformation.json') -and $u.jsonPath){
          $key  = $f.inputKey; $path = $u.jsonPath
          if($effectiveObj.PSObject.Properties.Name -contains $key){
            Set-JsonPathValue -obj $vsObj -jsonPath $path -value $effectiveObj.$key
            $audit.substitutions.success += "versionSetInformation.json: $path ← $key"
          } elseif($f.mandatory -and (-not $AllowMissing.IsPresent)){
            $audit.substitutions.missing += "versionSetInformation.json: $path ← $key (missing)"; $SubError = $true
          } else { Write-Warn "Missing optional field '$key' for $path" }
        }
      }
    }

    if($DryRun.IsPresent){ Write-Info "Plan to write $dstVersionInfo (tokenized JSON-first)" }
    else { Save-Json $vsObj $dstVersionInfo; $audit.filesCreated += $dstVersionInfo }
  }
} catch {
  Write-Err "versionSetInformation.json failure: $($_.Exception.Message)"; $SubError = $true
}

# -----------------------------------------------------------------------------
# policy.xml (diagnostics + deterministic replacement + braces) — DOUBLE ONLY
# -----------------------------------------------------------------------------
try{
  $tplPolicy = Tpl 'policy.xml'
  if(Handle-OverwriteAndBackup $dstPolicy){
    Write-Diag "policy.xml path: $tplPolicy"
    $polRaw = Get-Content -LiteralPath $tplPolicy -Raw
    Dump-Sample "policy.xml raw" $polRaw $DiagDumpChars | Out-Null
    Save-SampleFile "policy.xml" "raw" $polRaw $DiagDumpChars

    $polText = Normalize-EncodedText $polRaw
    Dump-Sample "policy.xml normalized" $polText $DiagDumpChars | Out-Null
    Save-SampleFile "policy.xml" "normalized" $polText $DiagDumpChars

    # Pre-flight preview (DOUBLE ONLY)
    $reDouble = '<<\s*([A-Za-z0-9_]+)\s*>>'
    $doubleNames = ([regex]::Matches($polText, $reDouble) | ForEach-Object { $_.Groups[1].Value.ToUpper() }) | Select-Object -Unique

    $preview = @(); $missing = @()
    foreach($tok in $doubleNames){
      $inputKey = $tok
      if($mappingObj.PSObject.Properties.Name -contains 'angleAliases' -and
         $mappingObj.angleAliases.PSObject.Properties.Name -contains $tok){
        $inputKey = [string]$mappingObj.angleAliases.$tok
      }
      $val = $null
      if($effectiveObj.PSObject.Properties.Name -contains $inputKey){ $val = [string]$effectiveObj.$inputKey }
      if([string]::IsNullOrWhiteSpace($val)){ $missing += "$tok -> missing input key '$inputKey'" }
      else { $preview += "$tok -> $inputKey = $val" }
    }
    if($preview.Count -gt 0){ Write-Info ("policy.xml token preview:`n - " + ($preview -join "`n - ")) }
    if(($missing.Count -gt 0) -and (-not $AllowMissing.IsPresent)){
      throw ("Required policy values missing:`n - " + ($missing -join "`n - "))
    }

    # Deterministic replacement for DOUBLE-ANGLE
    foreach($name in $doubleNames){
      $inputKey = $name
      if($mappingObj.PSObject.Properties.Name -contains 'angleAliases' -and
         $mappingObj.angleAliases.PSObject.Properties.Name -contains $name){
        $inputKey = [string]$mappingObj.angleAliases.$name
      }
      if(-not ($effectiveObj.PSObject.Properties.Name -contains $inputKey)){ continue }
      $val = [string]$effectiveObj.$inputKey
      if([string]::IsNullOrWhiteSpace($val)){ continue }

      $polText = $polText.Replace("<<$name>>", $val)
      $polText = [regex]::Replace($polText, ("<<\s*{0}\s*>>" -f [regex]::Escape($name)), [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $val })
    }

    # Brace tokens (case-insensitive)
    foreach($k in $tokens.Keys){
      $pattern = '(?i)\{\{\s*' + [regex]::Escape($k) + '\s*\}\}'
      $polText = [regex]::Replace($polText, $pattern, [string]$tokens[$k])
    }

    # Final unresolved check (DOUBLE + BRACE only)
    $left = @()
    $left += ([regex]::Matches($polText, $reDouble) | ForEach-Object { $_.Value })
    $left += ([regex]::Matches($polText, '\{\{\s*[A-Za-z0-9_\-]+\s*\}\}') | ForEach-Object { $_.Value })
    $left = $left | Select-Object -Unique
    if(($left.Count -gt 0) -and (-not $AllowMissing.IsPresent)){
      throw ("Unresolved placeholders remain in policy.xml after replacement: " + ($left -join ', '))
    }

    Dump-Sample "policy.xml replaced" $polText $DiagDumpChars | Out-Null
    Save-SampleFile "policy.xml" "replaced" $polText $DiagDumpChars

    if($DryRun.IsPresent){ Write-Info "Plan to write $dstPolicy" }
    else { Save-Text $polText $dstPolicy; $audit.filesCreated += $dstPolicy }
    $audit.substitutions.success += "policy.xml substitutions completed"
  }
} catch {
  Write-Err "policy.xml failure: $($_.Exception.Message)"; $SubError = $true
}

# -----------------------------------------------------------------------------
# specification.yaml (tokenize either external spec or template spec)
# -----------------------------------------------------------------------------
try{
  if(Handle-OverwriteAndBackup $dstSpec){
    if($SpecPath){
      if(Test-Path -LiteralPath $SpecPath){
        $specText = Load-TemplateText-WithTokens -templatePath $SpecPath -effectiveObj $effectiveObj -braceTokens $tokens -mappingObj $mappingObj -AllowMissing:$AllowMissing -label "specification.yaml (external)"
        if($DryRun.IsPresent){ Write-Info "Plan to write spec → $dstSpec (tokenized external)" }
        else { Save-Text $specText $dstSpec; $audit.filesCreated += $dstSpec }
      } else {
        if($AllowMissing.IsPresent){
          Write-Warn "SpecPath not found; writing stub specification.yaml"
          if(-not $DryRun.IsPresent){ Save-Text "# TODO: provide OpenAPI spec" $dstSpec; $audit.filesCreated += $dstSpec }
        } else { throw "SpecPath '$SpecPath' does not exist" }
      }
    } else {
      $tplSpec = Tpl 'specification.yaml'
      if(Test-Path -LiteralPath $tplSpec){
        $specText = Load-TemplateText-WithTokens -templatePath $tplSpec -effectiveObj $effectiveObj -braceTokens $tokens -mappingObj $mappingObj -AllowMissing:$AllowMissing -label "specification.yaml"
        if($DryRun.IsPresent){ Write-Info "Plan to write template spec → $dstSpec (tokenized)" }
        else { Save-Text $specText $dstSpec; $audit.filesCreated += $dstSpec }
      } else {
        if($AllowMissing.IsPresent){
          if(-not $DryRun.IsPresent){ Save-Text "# TODO: provide OpenAPI spec" $dstSpec; $audit.filesCreated += $dstSpec }
        } else { throw "specification.yaml required (no SpecPath provided and no template found)" }
      }
    }
  }
} catch {
  Write-Err "specification.yaml failure: $($_.Exception.Message)"; $SubError = $true
}

# -----------------------------------------------------------------------------
# Reports
# -----------------------------------------------------------------------------
$reportDir = Join-Path $OutRoot "reports"
Ensure-Dir $reportDir | Out-Null
$reportJson = Join-Path $reportDir "scaffold-$($CorrelationId).json"
$reportMd   = Join-Path $reportDir "scaffold-$($CorrelationId).md"

($audit | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $reportJson

$md = @"
# APIM Self-Serve Scaffold Report
- **Correlation ID**: $CorrelationId
- **Timestamp**: $Timestamp
- **Input JSON**: $($audit.inputJson)
- **Schema**: $($audit.schema)
- **Schema Version**: $($audit.schemaVersion)
- **Mapping**: $($audit.mapping)
- **Templates Root**: $($audit.templatesRoot)
- **Output Root**: $($audit.outRoot)
- **Environment**: $Environment
- **Dry Run**: $([bool]$DryRun)
- **Overwrite**: $([bool]$Overwrite)
- **Allow Missing**: $([bool]$AllowMissing)
- **Diagnostics**: $([bool]$Diagnostics)
- **Diag Dump Chars**: $DiagDumpChars
- **Diag Samples**: $([bool]$DiagSaveSamples)

## Plan (folders)
$(( $audit.plan.folders | ForEach-Object { "- " + $_ } ) -join "`n")

## Plan (files)
$(( $audit.plan.files | ForEach-Object { "- " + $_ } ) -join "`n")

## Substitutions - success
$(( $audit.substitutions.success | ForEach-Object { "- " + $_ } ) -join "`n")

## Substitutions - missing
$(( $audit.substitutions.missing | ForEach-Object { "- " + $_ } ) -join "`n")

## Warnings
$(( $audit.substitutions.warnings | ForEach-Object { "- " + $_ } ) -join "`n")

## Errors
$(( $audit.errors | ForEach-Object { "- " + $_ } ) -join "`n")
"@
Set-Content -LiteralPath $reportMd -Value $md

# -----------------------------------------------------------------------------
# Exit semantics
# -----------------------------------------------------------------------------
if($ExitCodeFS -eq 3){ Write-Err "Filesystem errors encountered. Exit code = 3"; exit 3 }
if($valErrors.Count -gt 0){ Write-Err "Validation errors encountered. Exit code = 1"; exit 1 }
if($SubError){ Write-Err "Substitution errors encountered. Exit code = 2"; exit 2 }
Write-Host "✅ Completed. Reports:`n- $reportJson`n- $reportMd`nDiag log (if enabled):`n- $diagLog" -ForegroundColor Green
exit 0
