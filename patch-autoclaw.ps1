param(
  [string]$AppPath = $env:AUTOCLAW_APP_PATH,
  [switch]$SkipRunningCheck
)

$ErrorActionPreference = "Stop"

function Log($message) {
  Write-Host "[autoclaw-patcher] $message"
}

function Fail($message) {
  Write-Error "[autoclaw-patcher] ERROR: $message"
  exit 1
}

function Find-AutoClawAppPath {
  $candidates = @()

  if ($env:AUTOCLAW_APP_PATH) {
    $candidates += $env:AUTOCLAW_APP_PATH
  }

  $localAppData = [Environment]::GetFolderPath("LocalApplicationData")
  $programFiles = [Environment]::GetFolderPath("ProgramFiles")
  $programFilesX86 = [Environment]::GetFolderPath("ProgramFilesX86")

  $candidates += @(
    (Join-Path $localAppData "Programs\AutoClaw"),
    (Join-Path $localAppData "AutoClaw"),
    (Join-Path $programFiles "AutoClaw"),
    (Join-Path $programFilesX86 "AutoClaw")
  )

  foreach ($candidate in $candidates) {
    if (-not $candidate) { continue }
    $resources = Join-Path $candidate "resources"
    $asar = Join-Path $resources "app.asar"
    if (Test-Path $asar) {
      return $candidate
    }
  }

  $roots = @($localAppData, $programFiles, $programFilesX86) | Where-Object { $_ -and (Test-Path $_) }
  foreach ($root in $roots) {
    $match = Get-ChildItem -Path $root -Filter "app.asar" -Recurse -ErrorAction SilentlyContinue |
      Where-Object { $_.FullName -match "\\AutoClaw\\resources\\app\.asar$" } |
      Select-Object -First 1
    if ($match) {
      return (Split-Path (Split-Path $match.FullName -Parent) -Parent)
    }
  }

  return $null
}

if (-not $AppPath) {
  $AppPath = Find-AutoClawAppPath
}

if (-not $AppPath) {
  Fail "AutoClaw install folder not found. Pass -AppPath or set AUTOCLAW_APP_PATH."
}

$ResourcesDir = Join-Path $AppPath "resources"
$AsarPath = Join-Path $ResourcesDir "app.asar"

if (-not (Test-Path $AsarPath)) {
  Fail "File not found: $AsarPath"
}

if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
  Fail "node is required"
}

if (-not (Get-Command npx -ErrorAction SilentlyContinue)) {
  Fail "npx is required"
}

if (-not $SkipRunningCheck -and $env:AUTOCLAW_SKIP_RUNNING_CHECK -ne "1") {
  $running = Get-Process -Name "AutoClaw" -ErrorAction SilentlyContinue
  if ($running) {
    Log "AutoClaw appears to be running. Please quit it before patching."
    Fail "AutoClaw is still running"
  }
}

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backupDir = if ($env:AUTOCLAW_BACKUP_DIR) { $env:AUTOCLAW_BACKUP_DIR } else { Join-Path $ResourcesDir "autoclaw-patcher-backups" }
$backupPath = Join-Path $backupDir "app.asar.$stamp.bak"
$tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ("autoclaw-patch." + [System.Guid]::NewGuid().ToString("N"))
$extractDir = Join-Path $tmpDir "app"
$packedAsar = Join-Path $tmpDir "app.asar"

try {
  Log "Using AutoClaw folder: $AppPath"
  Log "Working directory: $tmpDir"

  New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
  New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null
  Copy-Item -Path $AsarPath -Destination $backupPath -Force
  Log "Backup created: $backupPath"

  Log "Extracting app.asar"
  npx --yes "@electron/asar" extract "$AsarPath" "$extractDir"
  if ($LASTEXITCODE -ne 0) { Fail "Failed to extract app.asar" }

  $mainFile = Join-Path $extractDir "out\main\index.js"
  if (-not (Test-Path $mainFile)) { Fail "Main bundle not found: $mainFile" }

  $rendererDir = Join-Path $extractDir "out\renderer\assets"
  $rendererFile = Get-ChildItem -Path $rendererDir -Filter "index-*.js" | Select-Object -First 1
  if (-not $rendererFile) { Fail "Renderer bundle not found" }

  Log "Patching main process output checker"
  @'
const fs = require("fs");
const file = process.argv[2];
let text = fs.readFileSync(file, "utf8");

const marker = "async function agentOutputCheck({ output }) {";
const start = text.indexOf(marker);
if (start < 0) {
  console.error("agentOutputCheck function not found");
  process.exit(2);
}
const next = text.indexOf("\nasync function ", start + marker.length);
if (next < 0) {
  console.error("Could not find end of agentOutputCheck function");
  process.exit(2);
}

const replacement = `async function agentOutputCheck({ output }) {
  return {
    ok: true,
    code: 0,
    msg: "output check disabled by autoclaw-output-check-patcher",
    data: { sensitive: false, answer: "" },
    trace: void 0,
    stage: "local-patch"
  };
}
`;

text = text.slice(0, start) + replacement + text.slice(next + 1);
fs.writeFileSync(file, text);
'@ | node - "$mainFile"
  if ($LASTEXITCODE -ne 0) { Fail "Failed to patch main process output checker" }

  Log "Patching renderer output replacement hook"
  @'
const fs = require("fs");
const file = process.argv[2];
let text = fs.readFileSync(file, "utf8");
const needle = "window.electronAPI.agent.outputCheck({ output: outputContent }).then((outputCheckRes) => {";
const replacement = "Promise.resolve({ data: { sensitive: false, answer: \"\" } }).then((outputCheckRes) => {";
const count = text.split(needle).length - 1;
if (count < 1) {
  console.error("Renderer outputCheck hook not found");
  process.exit(2);
}
text = text.split(needle).join(replacement);
fs.writeFileSync(file, text);
console.log(`patched ${count} renderer hook(s)`);
'@ | node - "$($rendererFile.FullName)"
  if ($LASTEXITCODE -ne 0) { Fail "Failed to patch renderer output replacement hook" }

  Log "Verifying patch markers"
  $mainText = Get-Content -Raw -Path $mainFile
  $rendererText = Get-Content -Raw -Path $rendererFile.FullName
  if (-not $mainText.Contains('stage: "local-patch"')) { Fail "Main patch marker missing" }
  if (-not $rendererText.Contains('Promise.resolve({ data: { sensitive: false')) { Fail "Renderer patch marker missing" }

  if ($mainText.Contains('/agentdr/v1/assistant/claw-output-check')) {
    Log "Endpoint string still exists in bundle, but patched agentOutputCheck no longer calls it."
  }

  Log "Repacking app.asar"
  npx --yes "@electron/asar" pack "$extractDir" "$packedAsar"
  if ($LASTEXITCODE -ne 0) { Fail "Failed to repack app.asar" }
  Copy-Item -Path $packedAsar -Destination $AsarPath -Force

  Log "Patch complete. Restart AutoClaw."
  Log "To restore: Copy-Item -Force '$backupPath' '$AsarPath'"
}
finally {
  if (Test-Path $tmpDir) {
    Remove-Item -Recurse -Force $tmpDir
  }
}
