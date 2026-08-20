<#
.SYNOPSIS
    Migrates a QBCore resources folder to Qbox (qbx_core + ox stack).

.DESCRIPTION
    Two things happen here, and only one of them touches your files:

      1. AUDIT  - always runs. Scans every .lua / fxmanifest / cfg under -ResourcesPath,
                  classifies every QBCore-ism it finds, and writes a ranked markdown
                  report. Nothing is modified.

      2. REWRITE - only with -Apply. Applies the mechanical, provably-safe rewrites
                  (marked Auto in the rule table below). Every file it touches is
                  copied to <output>\backup\<relative path> first, and a
                  Restore-Backup.ps1 is generated next to it.

    Anything that cannot be rewritten safely is reported with file, line, and the
    suggested replacement. It is never guessed at.

.PARAMETER ResourcesPath
    Path to your server's resources folder (the one containing [qb], [standalone], etc).

.PARAMETER OutputPath
    Where the report and backups go. Defaults to .\qbx_migration_<timestamp> next to this script.

.PARAMETER Apply
    Actually write the auto-fixes. Without this the script is read-only.

.PARAMETER Aggressive
    Also apply medium-confidence rewrites. Read the report from a normal run first.

.PARAMETER ServerCfg
    Optional path to server.cfg. Audited for `ensure qb-*` lines.

.EXAMPLE
    .\Convert-QbxResources.ps1 -ResourcesPath 'C:\FXServer\server-data\resources'

.EXAMPLE
    .\Convert-QbxResources.ps1 -ResourcesPath 'C:\FXServer\server-data\resources' -Apply
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $ResourcesPath,

    [string] $OutputPath,

    [switch] $Apply,

    [switch] $Aggressive,

    [string] $ServerCfg,

    [string[]] $ExcludeDir = @()
)

$ErrorActionPreference = 'Stop'

# =====================================================================================
# RESOURCE REPLACEMENT MAP
# =====================================================================================

$ResourceMap = [ordered]@{
    'qb-core'             = 'qbx_core'
    'qb-inventory'        = 'ox_inventory  (data conversion required - see qbxmigrate inventory)'
    'qs-inventory'        = 'ox_inventory  (run `qbxmigrate inspect` first - Quasar does not publish its schema)'
    'ps-inventory'        = 'ox_inventory  (data conversion required - see qbxmigrate inventory)'
    'lj-inventory'        = 'ox_inventory  (data conversion required - see qbxmigrate inventory)'
    'origen_inventory'    = 'ox_inventory  (data conversion required - see qbxmigrate inventory)'
    'codem-inventory'     = 'ox_inventory  (data conversion required - see qbxmigrate inventory)'
    'qb-target'           = 'ox_target  (qtarget compat layer covers most calls)'
    'qb-menu'             = 'ox_lib lib.registerContext  (shim included in qbx_migrate\shims\qb-menu)'
    'qb-input'            = 'ox_lib lib.inputDialog  (shim included in qbx_migrate\shims\qb-input)'
    'progressbar'         = 'ox_lib lib.progressBar  (shim included in qbx_migrate\shims\progressbar)'
    'qb-policejob'        = 'qbx_police'
    'qb-ambulancejob'     = 'qbx_ambulancejob'
    'qb-garages'          = 'qbx_garages'
    'qb-management'       = 'qbx_management'
    'qb-cityhall'         = 'qbx_cityhall'
    'qb-adminmenu'        = 'qbx_adminmenu'
    'qb-smallresources'   = 'qbx_smallresources'
    'qb-vehiclesales'     = 'qbx_vehiclesales'
    'qb-taxijob'          = 'qbx_taxijob'
    'qb-recyclejob'       = 'qbx_recyclejob'
    'qb-jewelery'         = 'qbx_jewelery'
    'qb-diving'           = 'qbx_diving'
    'qb-drugs'            = 'qbx_drugs'
    'qb-radio'            = 'qbx_radio'
    'qb-vehiclekeys'      = 'qbx_vehiclekeys'
    'qb-doorlock'         = 'ox_doorlock  (door data must be re-created)'
    'qb-fuel'             = 'ox_fuel'
    'LegacyFuel'          = 'ox_fuel'
    'qb-clothing'         = 'illenium-appearance'
    'qb-skinshop'         = 'illenium-appearance'
    'fivem-appearance'    = 'illenium-appearance'
    'qb-multicharacter'   = 'qbx_core built-in multicharacter (set useExternalCharacters = false)'
    'qb-spawn'            = 'qbx_core built-in spawn'
    'qb-apartments'       = 'qbx_core built-in apartments, or ps-housing'
    'qb-houses'           = 'qbx_houses (UNMAINTAINED) or ps-housing'
    'qb-banking'          = 'Renewed-Banking'
    'qb-phone'            = 'npwd + qbx_npwd (or lb-phone / qs-smartphone)'
    'qb-weathersync'      = 'qbx_weathersync / Renewed-Weathersync'
    'qb-weapons'          = 'ox_inventory (weapons are items in ox)'
    'qb-shops'            = 'ox_inventory shops (ox_inventory/data/shops.lua)'
    'qb-radialmenu'       = 'ox_target, or qbx_radialmenu'
    'qb-logs'             = 'ox_lib logger / qbx_core logger'
    'qb-vehiclefailure'   = 'qbx_smallresources'
    'qb-hud'              = 'works via the qbx_core qb bridge, or swap to a qbx hud'
    'qb-tunerchip'        = 'qbx_tunerchip (UNMAINTAINED)'
    'qb-fitbit'           = 'qbx_fitbit (UNMAINTAINED)'
    'PolyZone'            = 'ox_lib zones (lib.zones.box / .sphere / .poly)'
    'qtarget'             = 'ox_target'
    'mysql-async'         = 'oxmysql'
    'ghmattimysql'        = 'oxmysql'
}

# =====================================================================================
# RULES
#   Severity : HIGH   = will break at runtime, needs a human
#              MEDIUM = probably breaks, needs a human
#              LOW    = works today via a bridge/shim, clean up when convenient
#              INFO   = no action needed, listed so you know it was seen
#   Auto     : 'safe'       -> rewritten by -Apply
#              'aggressive' -> rewritten only by -Apply -Aggressive
#              $null        -> report only, never rewritten
# =====================================================================================

$Rules = @(
    # ---------------------------------------------------------------- core object
    @{ Id = 'core.export'
       Severity = 'HIGH'; Auto = 'safe'
       Pattern = 'exports\[.qb-core.\]'
       Replacement = "exports['qbx_core']"
       Note = "qb-core no longer exists. qbx_core exposes the same GetCoreObject bridge." }

    @{ Id = 'core.shared-lua-import'
       Severity = 'HIGH'; Auto = $null
       Pattern = '@qb-core/[\w/\.\-]+'
       Note = "qbx_core does not mirror qb-core's file layout. Replace shared_script '@qb-core/...' imports with '@ox_lib/init.lua' plus the qbx_core exports." }

    @{ Id = 'core.manifest-dependency'
       Severity = 'MEDIUM'; Auto = 'safe'
       Pattern = "(dependenc(?:y|ies)\s*[\{\s]\s*)(['`"])qb-core\2"
       Replacement = '$1$2qbx_core$2'
       Note = 'fxmanifest dependency renamed.'
       ManifestOnly = $true }

    # ---------------------------------------------------------------- ox_target
    @{ Id = 'target.passthrough'
       Severity = 'HIGH'; Auto = 'safe'
       Pattern = 'exports\[.qb-target.\]:(AddBoxZone|AddPolyZone|AddCircleZone|AddSphereZone|RemoveZone|AddTargetBone|AddTargetEntity|RemoveTargetEntity|AddTargetModel|RemoveTargetModel)'
       Replacement = "exports['ox_target']:`$1"
       Note = "ox_target ships a qtarget compatibility layer with identical signatures for these." }

    @{ Id = 'target.global-ped'
       Severity = 'HIGH'; Auto = 'safe'
       Pattern = 'exports\[.qb-target.\]:AddGlobalPed'
       Replacement = "exports['ox_target']:Ped"
       Note = 'qb-target AddGlobalPed -> qtarget compat Ped.' }

    @{ Id = 'target.global-vehicle'
       Severity = 'HIGH'; Auto = 'safe'
       Pattern = 'exports\[.qb-target.\]:AddGlobalVehicle'
       Replacement = "exports['ox_target']:Vehicle"
       Note = 'qb-target AddGlobalVehicle -> qtarget compat Vehicle.' }

    @{ Id = 'target.global-object'
       Severity = 'HIGH'; Auto = 'safe'
       Pattern = 'exports\[.qb-target.\]:AddGlobalObject'
       Replacement = "exports['ox_target']:Object"
       Note = 'qb-target AddGlobalObject -> qtarget compat Object.' }

    @{ Id = 'target.global-player'
       Severity = 'HIGH'; Auto = 'safe'
       Pattern = 'exports\[.qb-target.\]:AddGlobalPlayer'
       Replacement = "exports['ox_target']:Player"
       Note = 'qb-target AddGlobalPlayer -> qtarget compat Player.' }

    @{ Id = 'target.remove-globals'
       Severity = 'HIGH'; Auto = 'safe'
       Pattern = 'exports\[.qb-target.\]:RemoveGlobal(Ped|Vehicle|Object|Player)'
       Replacement = "exports['ox_target']:Remove`$1"
       Note = 'qb-target RemoveGlobalX -> qtarget compat RemoveX.' }

    @{ Id = 'target.unsupported'
       Severity = 'HIGH'; Auto = $null
       Pattern = 'exports\[.qb-target.\]:(AddEntityZone|AddComboZone|RemoveEntityZone|SpawnPed|RemovePed\()'
       Note = 'No ox_target equivalent. Rewrite as addEntity / addModel / a lib.zones zone.' }

    @{ Id = 'target.leftover'
       Severity = 'HIGH'; Auto = $null
       Pattern = 'exports\[.qb-target.\]'
       Note = 'Remaining qb-target call with no automatic mapping - convert by hand to the ox_target API.' }

    # ---------------------------------------------------------------- inventory (never auto)
    @{ Id = 'inventory.player-methods'
       Severity = 'HIGH'; Auto = $null
       Pattern = '\.Functions\.(AddItem|RemoveItem|GetItemByName|GetItemBySlot|GetItemsByName|SetInventory|ClearInventory|SaveInventory|GetTotalWeight|GetSlotsByItem|GetFirstSlotByItem)\s*\('
       Note = "Player item methods are stubs under qbx_core and assert against ox_inventory. Use exports.ox_inventory:AddItem(source, name, count, metadata, slot) / :RemoveItem(source, name, count, metadata, slot) / :Search(source, 'count', name) / :GetSlot(source, slot)." }

    @{ Id = 'inventory.qbcore-functions'
       Severity = 'HIGH'; Auto = $null
       Pattern = 'QBCore\.Functions\.(AddItem|RemoveItem|AddItems|UpdateItem|UseItem)\s*\('
       Note = 'Deprecated in the qbx_core bridge and incompatible with ox_inventory. Call ox_inventory exports directly.' }

    @{ Id = 'inventory.playerdata-items'
       Severity = 'HIGH'; Auto = $null
       Pattern = '\.PlayerData\.items'
       Note = 'PlayerData.items is not maintained under ox_inventory. Use exports.ox_inventory:GetInventoryItems(source) or :Search(source, ...).' }

    @{ Id = 'inventory.exports'
       Severity = 'HIGH'; Auto = $null
       Pattern = 'exports\[.(qb|qs|ps|lj|codem)-inventory.\]|exports\[.origen_inventory.\]'
       Note = 'Rewrite against the ox_inventory API. Stash/shop/drop concepts differ - see ox_inventory docs.' }

    @{ Id = 'inventory.qs-events'
       Severity = 'HIGH'; Auto = $null
       Pattern = "['`"](qs-inventory|ps-inventory|lj-inventory|codem-inventory|origen_inventory):[\w:]+['`"]"
       Note = 'Third-party inventory net event. No equivalent in ox_inventory - rewrite against its exports.' }

    @{ Id = 'inventory.events'
       Severity = 'HIGH'; Auto = $null
       Pattern = "['`"]inventory:(client|server):[\w]+['`"]"
       Note = 'qb-inventory net events do not exist in ox_inventory. Replace with ox_inventory exports.' }

    @{ Id = 'inventory.open-stash'
       Severity = 'HIGH'; Auto = $null
       Pattern = "['`"]inventory:server:OpenInventory['`"]|['`"]qb-inventory:server:[\w]+['`"]"
       Note = "Use exports.ox_inventory:RegisterStash(id, label, slots, weight, owner) plus TriggerEvent('ox_inventory:openInventory', ...)." }

    @{ Id = 'inventory.hasitem'
       Severity = 'LOW'; Auto = $null
       Pattern = 'QBCore\.Functions\.HasItem\s*\('
       Note = "Bridged to ox_inventory by qbx_core, still works. Cleaner: exports.ox_inventory:Search(source, 'count', item)." }

    @{ Id = 'inventory.useable'
       Severity = 'LOW'; Auto = $null
       Pattern = 'CreateUseableItem\s*\('
       Note = 'Works via the bridge, but the item MUST exist in ox_inventory/data/items.lua or the callback never fires.' }

    # ---------------------------------------------------------------- job grades
    @{ Id = 'jobs.grade-string-compare'
       Severity = 'HIGH'; Auto = 'safe'
       Pattern = '(\.grade\.level\s*(?:==|~=|>=|<=|>|<)\s*)[''"](\d+)[''"]'
       Replacement = '$1$2'
       Note = 'Qbox job grades are numbers, not strings.' }

    @{ Id = 'jobs.grade-string-reverse'
       Severity = 'HIGH'; Auto = $null
       Pattern = '[''"](\d+)[''"]\s*(?:==|~=|>=|<=|>|<)\s*[\w\.\[\]''"]*\.grade\.level'
       Note = 'Quoted grade compared against a numeric grade level. Drop the quotes.' }

    @{ Id = 'jobs.grade-string-index'
       Severity = 'HIGH'; Auto = $null
       Pattern = '\[\s*tostring\s*\(\s*[\w\.]*\.grade\.level\s*\)\s*\]'
       Note = 'Grade used as a string table key. Qbox grades are numeric - drop the tostring().' }

    @{ Id = 'jobs.grade-config-string-keys'
       Severity = 'MEDIUM'; Auto = $null
       Pattern = 'grades\s*=\s*\{\s*\[[''"]\d+[''"]\]'
       Note = "Job/gang config uses string grade keys ('0'). qbx_core requires numeric keys ([0]). Run `qbxmigrate jobs apply` to regenerate these files." }

    # ---------------------------------------------------------------- ui shims
    @{ Id = 'ui.qb-menu'
       Severity = 'LOW'; Auto = $null
       Pattern = 'exports\[.qb-menu.\]'
       Note = 'Covered by the qb-menu shim in qbx_migrate\shims. Long term: lib.registerContext / lib.showContext.' }

    @{ Id = 'ui.qb-input'
       Severity = 'LOW'; Auto = $null
       Pattern = 'exports\[.qb-input.\]'
       Note = 'Covered by the qb-input shim in qbx_migrate\shims. Long term: lib.inputDialog.' }

    @{ Id = 'ui.progressbar'
       Severity = 'LOW'; Auto = $null
       Pattern = 'exports\[.progressbar.\]'
       Note = 'Covered by the progressbar shim in qbx_migrate\shims. Long term: lib.progressBar / lib.progressCircle.' }

    @{ Id = 'ui.qb-notify'
       Severity = 'INFO'; Auto = $null
       Pattern = "['`"]QBCore:Notify['`"]"
       Note = 'Bridged by qbx_core. No change needed.' }

    # ---------------------------------------------------------------- zones
    @{ Id = 'zones.polyzone'
       Severity = 'MEDIUM'; Auto = $null
       Pattern = '(BoxZone|CircleZone|PolyZone|ComboZone|EntityZone)[:\.]Create|exports\[.PolyZone.\]'
       Note = 'PolyZone is not part of the Qbox stack. Replace with lib.zones.box / lib.zones.sphere / lib.zones.poly from ox_lib.' }

    # ---------------------------------------------------------------- misc bridged
    @{ Id = 'misc.callbacks'
       Severity = 'INFO'; Auto = $null
       Pattern = 'QBCore\.Functions\.(CreateCallback|TriggerCallback)\s*\('
       Note = 'Bridged by qbx_core and still functional. lib.callback is the native Qbox way.' }

    @{ Id = 'misc.playerloaded-events'
       Severity = 'INFO'; Auto = $null
       Pattern = "['`"]QBCore:(Client|Server):(OnPlayerLoaded|OnPlayerUnload|OnJobUpdate|OnGangUpdate|SetDuty)['`"]"
       Note = 'Bridged by qbx_core. Native equivalents: qbx_core:client:onPlayerLoaded, qbx_core:server:onGroupUpdate, etc.' }

    @{ Id = 'misc.debug'
       Severity = 'INFO'; Auto = $null
       Pattern = 'QBCore\.Debug\s*\('
       Note = 'Use lib.print from ox_lib.' }

    @{ Id = 'misc.mysql-async'
       Severity = 'LOW'; Auto = $null
       Pattern = 'MySQL\.Async\.|MySQL\.Sync\.|exports\[.mysql-async.\]|exports\[.ghmattimysql.\]'
       Note = "oxmysql still ships the MySQL.Async compatibility layer, so this runs. Modernise to MySQL.query.await when convenient." }

    @{ Id = 'misc.spawn-vehicle'
       Severity = 'MEDIUM'; Auto = $null
       Pattern = 'QBCore\.Functions\.(SpawnVehicle|CreateVehicle)\s*\('
       Note = 'Deprecated in the bridge. Use qbx.spawnVehicle (client) or CreateVehicleServerSetter / qbx_core CreateVehicle (server).' }

    @{ Id = 'misc.permissions'
       Severity = 'MEDIUM'; Auto = $null
       Pattern = 'QBCore\.Functions\.(AddPermission|RemovePermission|HasPermission|GetPermission)\s*\('
       Note = 'Deprecated as of qbx_core v1.8.0. Use ox_lib ACE permissions (lib.addAce / IsPlayerAceAllowed).' }

    @{ Id = 'misc.shared-items'
       Severity = 'INFO'; Auto = $null
       Pattern = 'QBCore\.Shared\.Items'
       Note = 'qbx_core rebuilds this table from ox_inventory at runtime. Items missing from ox_inventory will be missing here too.' }

    @{ Id = 'misc.money-item'
       Severity = 'MEDIUM'; Auto = $null
       Pattern = "['`"](AddMoney|RemoveMoney)['`"]\s*\)|\.Functions\.(AddMoney|RemoveMoney|SetMoney)\s*\("
       Note = 'Still works, but ox_inventory mirrors cash as a `money` item. Do not also add/remove a cash item or you will duplicate funds.' }
)

# =====================================================================================
# SETUP
# =====================================================================================

if (-not (Test-Path -LiteralPath $ResourcesPath)) {
    throw "ResourcesPath not found: $ResourcesPath"
}
$ResourcesPath = (Resolve-Path -LiteralPath $ResourcesPath).Path

$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path -Path $PSScriptRoot -ChildPath "qbx_migration_$stamp"
}
if (-not (Test-Path -LiteralPath $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}
$OutputPath = (Resolve-Path -LiteralPath $OutputPath).Path
$backupRoot = Join-Path -Path $OutputPath -ChildPath 'backup'

$defaultExcludes = @(
    'node_modules', '.git', '.github', 'ox_lib', 'ox_inventory', 'ox_target', 'ox_doorlock',
    'ox_fuel', 'oxmysql', 'qbx_core', 'illenium-appearance', 'web\build', 'html\build', 'dist', '.vscode'
)
$allExcludes = @($defaultExcludes) + @($ExcludeDir)

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Test-Excluded {
    param([string] $FullPath)
    $rel = $FullPath.Substring($ResourcesPath.Length).TrimStart('\', '/')
    foreach ($ex in $allExcludes) {
        if ($rel -like "*\$ex\*" -or $rel -like "$ex\*" -or $rel -like "*\$ex" -or $rel -eq $ex) {
            return $true
        }
    }
    return $false
}

function Get-LineNumber {
    param([string] $Text, [int] $Index)
    if ($Index -le 0) { return 1 }
    $slice = $Text.Substring(0, $Index)
    return ([regex]::Matches($slice, "`n")).Count + 1
}

function Get-RelativePath {
    param([string] $FullPath)
    return $FullPath.Substring($ResourcesPath.Length).TrimStart('\', '/')
}

# =====================================================================================
# SCAN
# =====================================================================================

Write-Host "[qbx_migrate] scanning $ResourcesPath ..." -ForegroundColor Cyan

$targetFiles = Get-ChildItem -LiteralPath $ResourcesPath -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Extension -eq '.lua' -or $_.Extension -eq '.cfg' } |
    Where-Object { -not (Test-Excluded -FullPath $_.FullName) }

Write-Host "[qbx_migrate] $($targetFiles.Count) files in scope" -ForegroundColor Cyan

$findings = New-Object System.Collections.ArrayList
$modifiedFiles = New-Object System.Collections.ArrayList
$legacyRefs = @{}
$regexOpts = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase

foreach ($file in $targetFiles) {

    $original = [System.IO.File]::ReadAllText($file.FullName)
    if ([string]::IsNullOrWhiteSpace($original)) { continue }

    $text = $original
    $isManifest = ($file.Name -eq 'fxmanifest.lua' -or $file.Name -eq '__resource.lua')
    $rel = Get-RelativePath -FullPath $file.FullName
    $wouldChange = $false

    foreach ($rule in $Rules) {

        $manifestOnly = $false
        if ($rule.ContainsKey('ManifestOnly')) { $manifestOnly = [bool] $rule.ManifestOnly }
        if ($manifestOnly -and -not $isManifest) { continue }

        $ruleMatches = [regex]::Matches($text, $rule.Pattern, $regexOpts)
        if ($ruleMatches.Count -eq 0) { continue }

        $auto = $null
        if ($rule.ContainsKey('Auto')) { $auto = $rule.Auto }

        # Auto-fixes are applied to the in-memory copy even during a dry run, so that
        # later rules see the post-fix text. Without this, the catch-all "leftover"
        # rules would report calls that the earlier rules already handle, and a dry
        # run would not match what -Apply actually produces.
        $eligible = $false
        if ($auto -eq 'safe') { $eligible = $true }
        if ($Aggressive -and $auto -eq 'aggressive') { $eligible = $true }

        $willFix = $eligible

        foreach ($m in $ruleMatches) {
            $line = Get-LineNumber -Text $text -Index $m.Index
            $snippet = $m.Value
            if ($snippet.Length -gt 120) { $snippet = $snippet.Substring(0, 120) + '...' }
            [void] $findings.Add([pscustomobject]@{
                File     = $rel
                Line     = $line
                RuleId   = $rule.Id
                Severity = $rule.Severity
                Auto     = $auto
                Fixed    = ($willFix -and $Apply)
                Snippet  = $snippet
                Note     = $rule.Note
            })
        }

        if ($willFix) {
            $text = [regex]::Replace($text, $rule.Pattern, $rule.Replacement, $regexOpts)
            $wouldChange = $true
        }
    }

    # Tally every remaining legacy resource reference so nothing hides.
    foreach ($m in [regex]::Matches($text, 'exports\[.([\w\-]+).\]', $regexOpts)) {
        $name = $m.Groups[1].Value
        if ($ResourceMap.Contains($name)) {
            if (-not $legacyRefs.ContainsKey($name)) { $legacyRefs[$name] = 0 }
            $legacyRefs[$name] = $legacyRefs[$name] + 1
        }
    }

    if ($Apply -and $text -ne $original) {
        $backupPath = Join-Path -Path $backupRoot -ChildPath $rel
        $backupDir = Split-Path -Path $backupPath -Parent
        # .NET, not New-Item: resource folders like [qb] are wildcards to the PS provider.
        [void] [System.IO.Directory]::CreateDirectory($backupDir)
        [System.IO.File]::WriteAllText($backupPath, $original, $utf8NoBom)
        [System.IO.File]::WriteAllText($file.FullName, $text, $utf8NoBom)
        [void] $modifiedFiles.Add($rel)
        Write-Host "  fixed  $rel" -ForegroundColor Green
    }
    elseif (-not $Apply -and $wouldChange) {
        [void] $modifiedFiles.Add($rel)
    }
}

# =====================================================================================
# RESOURCE FOLDER AUDIT
# =====================================================================================

$installedResources = @{}
Get-ChildItem -LiteralPath $ResourcesPath -Recurse -Directory -ErrorAction SilentlyContinue |
    Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'fxmanifest.lua') -PathType Leaf } |
    ForEach-Object { $installedResources[$_.Name] = (Get-RelativePath -FullPath $_.FullName) }

$resourceFindings = New-Object System.Collections.ArrayList
foreach ($key in $ResourceMap.Keys) {
    if ($installedResources.ContainsKey($key)) {
        [void] $resourceFindings.Add([pscustomobject]@{
            Legacy      = $key
            Path        = $installedResources[$key]
            Replacement = $ResourceMap[$key]
        })
    }
}

$conflicts = New-Object System.Collections.ArrayList
$conflictPairs = @(
    @('qb-core', 'qbx_core'), @('qb-target', 'ox_target'), @('qb-inventory', 'ox_inventory'),
    @('qb-doorlock', 'ox_doorlock'), @('LegacyFuel', 'ox_fuel'), @('qb-fuel', 'ox_fuel'),
    @('mysql-async', 'oxmysql'), @('qtarget', 'ox_target')
)
foreach ($pair in $conflictPairs) {
    if ($installedResources.ContainsKey($pair[0]) -and $installedResources.ContainsKey($pair[1])) {
        [void] $conflicts.Add("$($pair[0]) and $($pair[1]) are both installed - make sure only one is ensured in server.cfg")
    }
}

# =====================================================================================
# SERVER.CFG AUDIT
# =====================================================================================

$cfgFindings = New-Object System.Collections.ArrayList
if (-not [string]::IsNullOrWhiteSpace($ServerCfg)) {
    if (Test-Path -LiteralPath $ServerCfg) {
        $cfgLines = Get-Content -LiteralPath $ServerCfg
        for ($i = 0; $i -lt $cfgLines.Count; $i++) {
            $lineText = $cfgLines[$i]
            if ($lineText -match '^\s*(ensure|start)\s+([\w\-]+)') {
                $resName = $Matches[2]
                if ($ResourceMap.Contains($resName)) {
                    [void] $cfgFindings.Add([pscustomobject]@{
                        Line        = ($i + 1)
                        Text        = $lineText.Trim()
                        Replacement = $ResourceMap[$resName]
                    })
                }
            }
        }
    }
    else {
        Write-Warning "ServerCfg not found: $ServerCfg"
    }
}

# =====================================================================================
# RESTORE SCRIPT
# =====================================================================================

if ($Apply -and $modifiedFiles.Count -gt 0) {
    $restore = @"
# Generated by Convert-QbxResources.ps1 on $stamp
# Restores every file that run modified back to its pre-migration content.
# Safe to run more than once.
`$ErrorActionPreference = 'Stop'
`$backupRoot = Join-Path `$PSScriptRoot 'backup'
`$target = '$ResourcesPath'

if (-not (Test-Path -LiteralPath `$backupRoot)) { throw "No backup folder at `$backupRoot" }
if (-not (Test-Path -LiteralPath `$target))     { throw "Resources folder not found: `$target" }

`$n = 0
Get-ChildItem -LiteralPath `$backupRoot -Recurse -File | ForEach-Object {
    `$rel  = `$_.FullName.Substring(`$backupRoot.Length).TrimStart('\')
    `$dest = Join-Path `$target `$rel
    `$destDir = Split-Path -Path `$dest -Parent
    if (-not (Test-Path -LiteralPath `$destDir)) {
        [void] [System.IO.Directory]::CreateDirectory(`$destDir)
    }
    # .NET copy, not Copy-Item: resource folders like [qb] are wildcards to the provider.
    [System.IO.File]::Copy(`$_.FullName, `$dest, `$true)
    `$n++
    Write-Host "restored `$rel"
}
Write-Host "Restore complete - `$n file(s)." -ForegroundColor Green
"@
    [System.IO.File]::WriteAllText((Join-Path $OutputPath 'Restore-Backup.ps1'), $restore, $utf8NoBom)
}

# =====================================================================================
# REPORT
# =====================================================================================

$severityOrder = @{ 'HIGH' = 0; 'MEDIUM' = 1; 'LOW' = 2; 'INFO' = 3 }

$md = New-Object System.Collections.ArrayList

function Add-Line {
    param([string] $Text = '')
    [void] $md.Add($Text)
}

Add-Line '# QBCore -> Qbox migration report'
Add-Line ''
Add-Line "Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Add-Line "Resources: ``$ResourcesPath``"
if ($Apply) { Add-Line 'Mode: **APPLY** - auto-fixes were written to disk.' }
else { Add-Line 'Mode: **DRY RUN** - nothing was modified.' }
if ($Aggressive) { Add-Line 'Aggressive rewrites: enabled.' }
Add-Line ''

$counts = @{}
foreach ($sev in @('HIGH', 'MEDIUM', 'LOW', 'INFO')) {
    $counts[$sev] = @($findings | Where-Object { $_.Severity -eq $sev }).Count
}
$fixedCount = @($findings | Where-Object { $_.Fixed }).Count

Add-Line '## Summary'
Add-Line ''
Add-Line "| metric | value |"
Add-Line "| --- | --- |"
Add-Line "| files scanned | $($targetFiles.Count) |"
Add-Line "| files changed | $($modifiedFiles.Count) |"
Add-Line "| auto-fixes applied | $fixedCount |"
Add-Line "| HIGH findings | $($counts['HIGH']) |"
Add-Line "| MEDIUM findings | $($counts['MEDIUM']) |"
Add-Line "| LOW findings | $($counts['LOW']) |"
Add-Line "| INFO findings | $($counts['INFO']) |"
Add-Line ''

if ($conflicts.Count -gt 0) {
    Add-Line '## Conflicts - fix these first'
    Add-Line ''
    foreach ($c in $conflicts) { Add-Line "- **$c**" }
    Add-Line ''
}

if ($resourceFindings.Count -gt 0) {
    Add-Line '## Legacy resources installed'
    Add-Line ''
    Add-Line '| resource | path | replace with |'
    Add-Line '| --- | --- | --- |'
    foreach ($r in $resourceFindings) {
        Add-Line "| ``$($r.Legacy)`` | ``$($r.Path)`` | $($r.Replacement) |"
    }
    Add-Line ''
}

if ($legacyRefs.Count -gt 0) {
    Add-Line '## Legacy resource references still in code (after auto-fixes)'
    Add-Line ''
    Add-Line '| resource | call sites | replace with |'
    Add-Line '| --- | --- | --- |'
    foreach ($k in ($legacyRefs.Keys | Sort-Object { -$legacyRefs[$_] })) {
        Add-Line "| ``$k`` | $($legacyRefs[$k]) | $($ResourceMap[$k]) |"
    }
    Add-Line ''
}

if ($cfgFindings.Count -gt 0) {
    Add-Line '## server.cfg'
    Add-Line ''
    Add-Line '| line | current | replace with |'
    Add-Line '| --- | --- | --- |'
    foreach ($c in $cfgFindings) {
        Add-Line "| $($c.Line) | ``$($c.Text)`` | $($c.Replacement) |"
    }
    Add-Line ''
}

Add-Line '## Findings by severity'

$grouped = $findings | Group-Object -Property RuleId
$sortedGroups = $grouped | Sort-Object -Property @{ Expression = { $severityOrder[$_.Group[0].Severity] } }, @{ Expression = { -$_.Count } }

foreach ($g in $sortedGroups) {
    $first = $g.Group[0]
    Add-Line ''
    Add-Line "### [$($first.Severity)] $($first.RuleId) - $($g.Count) hit(s)"
    Add-Line ''
    Add-Line $first.Note
    Add-Line ''
    if ($first.Auto -eq 'safe') { Add-Line '_Auto-fixable._' }
    elseif ($first.Auto -eq 'aggressive') { Add-Line '_Auto-fixable with -Aggressive._' }
    else { Add-Line '_Manual change required._' }
    Add-Line ''
    Add-Line '| file | line | snippet | fixed |'
    Add-Line '| --- | --- | --- | --- |'
    foreach ($f in ($g.Group | Sort-Object File, Line)) {
        $snip = $f.Snippet -replace '\|', '\|'
        $fixedMark = '-'
        if ($f.Fixed) { $fixedMark = 'yes' }
        Add-Line "| ``$($f.File)`` | $($f.Line) | ``$snip`` | $fixedMark |"
    }
}

Add-Line ''
Add-Line '## Next steps'
Add-Line ''
Add-Line '1. Resolve every **HIGH** finding above.'
Add-Line '2. Copy `qbx_migrate\shims\qb-menu`, `qb-input`, `progressbar` into your resources folder (only if you still have scripts calling them) and ensure them AFTER ox_lib.'
Add-Line '3. Run the database side: `qbxmigrate check` in the server console, then `qbxmigrate all apply`.'
Add-Line '4. Boot with a COPY of the database first. Never the live one.'
if ($Apply) {
    Add-Line ''
    Add-Line "Rollback for this run: ``$(Join-Path $OutputPath 'Restore-Backup.ps1')``"
}

$reportPath = Join-Path -Path $OutputPath -ChildPath 'MIGRATION_REPORT.md'
[System.IO.File]::WriteAllText($reportPath, ($md -join "`r`n"), $utf8NoBom)

# CSV for spreadsheet triage
$csvPath = Join-Path -Path $OutputPath -ChildPath 'findings.csv'
$findings | Sort-Object @{ Expression = { $severityOrder[$_.Severity] } }, File, Line |
    Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8

Write-Host ''
Write-Host "[qbx_migrate] HIGH:$($counts['HIGH'])  MEDIUM:$($counts['MEDIUM'])  LOW:$($counts['LOW'])  INFO:$($counts['INFO'])" -ForegroundColor Yellow
Write-Host "[qbx_migrate] report -> $reportPath" -ForegroundColor Cyan
Write-Host "[qbx_migrate] csv    -> $csvPath" -ForegroundColor Cyan
if ($Apply) {
    Write-Host "[qbx_migrate] $($modifiedFiles.Count) files rewritten, backups in $backupRoot" -ForegroundColor Green
}
else {
    Write-Host "[qbx_migrate] DRY RUN - $($modifiedFiles.Count) files would change. Re-run with -Apply." -ForegroundColor Yellow
}
