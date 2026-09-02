<#
.SYNOPSIS
    Sanitised sample. Automates the creation of a standardised Azure DevOps
    project. Replace every <placeholder> default below (or pass real values as
    arguments) before use. See ../README.md.

.DESCRIPTION
    Performs the following, matching a manual setup runbook:

      1. Create the project using a chosen process template (Git).
      2. Update organisation Group Rules so their members get Project
         Contributors access on the new project.
      3. Create a standard area-path structure:
           <Project>
             +- <Stream A>
             |    +- <Sub-Area 1>
             |    +- <Sub-Area 2>
             |    +- <Sub-Area 3>
             +- <Stream B>
                  +- <Sub-Area 1>
                  +- <Sub-Area 2>
                  +- <Sub-Area 3>
         and grant the delivery group Edit / Create Children / Delete on the
         project's root area node.
      4. Configure the default team:
           - Enable the Epic backlog level
           - Set the default area to include sub-areas
      5. Grant the delivery group Create / Delete / Rename / Remove Others'
         Locks on the project's Git repositories.
      6. Create branch policies on the default branch:
           - Minimum 1 reviewer + require approval on last iteration
           - Check for linked work items
           - Check for comment resolution
           - Limit merge types to "Rebase and fast-forward"
           - Auto-include the code reviewer group
      7. Create branch policies on release/* branches:
           - Same as above but limit merge to "Squash Merge"
      8. Create query sub-folders under Shared Queries and grant the delivery
         group Contribute / Delete / Manage Permissions on the Shared Queries
         folder.

    Runs both locally (with a confirmation prompt) and inside an Azure Pipelines
    job (auto-detected via $env:TF_BUILD; no prompt, and log output uses ADO log
    commands for collapsible sections + warnings).

.PARAMETER OrgUrl
    Organisation URL, e.g. https://dev.azure.com/<your-organisation-name>

.PARAMETER Pat
    Personal Access Token. Required scopes:
      - Project and Team (Read, Write, & Manage)
      - Code (Full)
      - Graph (Read & Manage)
      - Identity (Read & Manage)
      - Member Entitlement Management (Read & Write)
      - Security (Manage)

.PARAMETER ProjectName
    Name for the new project.

.PARAMETER ProjectDescription
    Optional description.

.PARAMETER ProcessName
    Process template to use. Set this to your org's process (e.g. "Agile",
    "Scrum", "CMMI", or a custom inherited process name).

.PARAMETER DevelopmentGroupPath
    Fully-qualified name of the security group that receives elevated area /
    repo / query permissions, e.g. "[<YourOrg>]\<Delivery Group>".

.PARAMETER CodeReviewerGroupPath
    Fully-qualified name of the group auto-included as reviewers,
    e.g. "[<YourOrg>]\<Code Reviewer Group>".

.PARAMETER GroupRuleNames
    Names of organisation Group Rules (Organisation Settings > Users > Group
    rules) that should be granted "Project Contributors" access on the new
    project.

.PARAMETER DefaultBranch
    Default branch name. Defaults to "main".

.EXAMPLE
    .\New-Project.ps1 `
        -OrgUrl      "https://dev.azure.com/<your-organisation-name>" `
        -Pat         $env:ADO_PAT `
        -ProjectName "Sample_Project" `
        -ProjectDescription "Sample engagement"
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory)] [string]   $OrgUrl,
    [Parameter(Mandatory)] [string]   $Pat,
    [Parameter(Mandatory)] [string]   $ProjectName,
    [string]   $ProjectDescription    = "",
    [string]   $ProcessName           = "<Your Process Template>",
    [string]   $DevelopmentGroupPath  = "[<YourOrg>]\<Delivery Group>",
    [string]   $CodeReviewerGroupPath = "[<YourOrg>]\<Code Reviewer Group>",
    [string[]] $GroupRuleNames        = @("<Group Rule 1>", "<Group Rule 2>"),
    [string]   $DefaultBranch         = "main"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Area-path structure to create. Replace with your own stream / sub-area names.
# ---------------------------------------------------------------------------
$Streams   = @("<Stream A>", "<Stream B>")
$SubAreas  = @("<Sub-Area 1>", "<Sub-Area 2>", "<Sub-Area 3>")

# Shared Queries sub-folders to create.
$QueryFolders = @("<Query Folder 1>", "<Query Folder 2>")

# Detect whether we're running inside an Azure Pipelines job
$script:InPipeline = [bool]$env:TF_BUILD

# Trim whitespace-only descriptions (pipeline param defaults sometimes send " ")
if ($ProjectDescription.Trim().Length -eq 0) { $ProjectDescription = "" }

Write-Host ""
Write-Host "Creating project: $ProjectName"   -ForegroundColor Yellow
Write-Host "In org:           $OrgUrl"         -ForegroundColor Yellow
Write-Host "Process template: $ProcessName"    -ForegroundColor Yellow
Write-Host "Default branch:   $DefaultBranch"  -ForegroundColor Yellow
Write-Host ""

if (-not $script:InPipeline) {
    $confirm = Read-Host "Proceed? (y/n)"
    if ($confirm -ne "y") {
        Write-Host "Cancelled." -ForegroundColor Red
        exit 1
    }
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

$script:OrgName  = ($OrgUrl.TrimEnd("/") -split "/")[-1]
$script:VsspsUrl = "https://vssps.dev.azure.com/$OrgName"
$script:VsaexUrl = "https://vsaex.dev.azure.com/$OrgName"

function Get-AuthHeader {
    param([string]$ContentType = "application/json")
    $token = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$Pat"))
    return @{ Authorization = "Basic $token"; "Content-Type" = $ContentType }
}

# Pipeline-aware logging.
function Write-Step {
    param([string]$m)
    if ($script:InPipeline) { Write-Host "##[section]$m" }
    else                    { Write-Host "`n>>  $m" -ForegroundColor Cyan }
}
function Write-Ok {
    param([string]$m)
    if ($script:InPipeline) { Write-Host "  [ok] $m" }
    else                    { Write-Host "   [ok] $m" -ForegroundColor Green }
}
function Write-Info {
    param([string]$m)
    if ($script:InPipeline) { Write-Host "  ..  $m" }
    else                    { Write-Host "    -  $m" -ForegroundColor Gray  }
}
function Write-Warn {
    param([string]$m)
    if ($script:InPipeline) { Write-Host "##vso[task.logissue type=warning]$m" }
    else                    { Write-Host "   [!]  $m" -ForegroundColor Yellow }
}

function Invoke-Ado {
    param(
        [string] $Method,
        [string] $Uri,
        [object] $Body        = $null,
        [string] $ContentType = "application/json",
        [switch] $Silent
    )
    $params = @{
        Method          = $Method
        Uri             = $Uri
        Headers         = Get-AuthHeader -ContentType $ContentType
        UseBasicParsing = $true
    }
    if ($null -ne $Body) {
        $params.Body = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 20 -Compress }
    }
    try {
        return Invoke-RestMethod @params
    }
    catch {
        $detail = $null
        try { $detail = $_.ErrorDetails.Message | ConvertFrom-Json -ErrorAction SilentlyContinue } catch {}
        $msg = if ($detail.message) { $detail.message } else { $_.Exception.Message }
        $fullMsg = "ADO API error [$Method $Uri]: $msg"
        if ($script:InPipeline -and -not $Silent) { Write-Host "##vso[task.logissue type=error]$fullMsg" }
        throw $fullMsg
    }
}

# ---------------------------------------------------------------------------
# 1. Create Project
# ---------------------------------------------------------------------------

Write-Step "Creating project '$ProjectName' using process '$ProcessName'..."

$processes = Invoke-Ado -Method GET -Uri "$OrgUrl/_apis/process/processes?api-version=7.1"
$process   = $processes.value | Where-Object { $_.name -eq $ProcessName } | Select-Object -First 1
if (-not $process) {
    $names = ($processes.value | ForEach-Object { $_.name }) -join ", "
    throw "Process '$ProcessName' not found. Available: $names"
}
Write-Info "Process id: $($process.id)"

$existingProject = $null
try {
    $existingProject = Invoke-Ado -Method GET -Uri "$OrgUrl/_apis/projects/$ProjectName`?api-version=7.1" -Silent
} catch {}

if ($existingProject) {
    Write-Warn "Project '$ProjectName' already exists (id: $($existingProject.id)). Continuing with configuration steps."
    $projectId = $existingProject.id
}
else {
    $projectBody = @{
        name         = $ProjectName
        description  = $ProjectDescription
        visibility   = "private"
        capabilities = @{
            versioncontrol  = @{ sourceControlType = "Git" }
            processTemplate = @{ templateTypeId    = $process.id }
        }
    }
    $op = Invoke-Ado -Method POST -Uri "$OrgUrl/_apis/projects?api-version=7.1" -Body $projectBody

    Write-Info "Waiting for provisioning..."
    $timeout = [DateTime]::UtcNow.AddSeconds(180)
    $project = $null
    do {
        Start-Sleep -Seconds 3
        $status = Invoke-Ado -Method GET -Uri "$OrgUrl/_apis/operations/$($op.id)?api-version=7.1"
        Write-Info "  status: $($status.status)"
        if ($status.status -eq "succeeded") {
            $project = Invoke-Ado -Method GET -Uri "$OrgUrl/_apis/projects/$ProjectName`?api-version=7.1"
            break
        }
        if ($status.status -in @("failed","cancelled")) { throw "Project creation failed: $($status.resultMessage)" }
    } while ([DateTime]::UtcNow -lt $timeout)

    if (-not $project) { throw "Timed out waiting for project provisioning." }
    $projectId = $project.id
    Write-Ok "Project created (id: $projectId)"
}

# ---------------------------------------------------------------------------
# 2. Group Rules - grant "Project Contributors" access on this project
# ---------------------------------------------------------------------------

Write-Step "Updating Group Rules for '$ProjectName'..."

$groupEntitlements = Invoke-Ado -Method GET `
    -Uri "$VsaexUrl/_apis/GroupEntitlements?api-version=7.1-preview.1"

foreach ($ruleName in $GroupRuleNames) {
    $rule = $groupEntitlements.value | Where-Object {
        $_.group.displayName -eq $ruleName -or
        $_.group.principalName -like "*\$ruleName" -or
        $_.group.principalName -eq $ruleName
    } | Select-Object -First 1

    if (-not $rule) {
        Write-Warn "Group rule '$ruleName' not found - skipping."
        continue
    }

    # Build the JSON Patch document as a raw string to avoid PowerShell's
    # single-item-array unwrapping in ConvertTo-Json.
    $patch = @"
[{"from":"","op":"add","path":"/projectEntitlements","value":{"projectRef":{"id":"$projectId"},"group":{"groupType":"ProjectContributor"}}}]
"@

    $uri = "$VsaexUrl/_apis/GroupEntitlements/$($rule.id)?ruleOption=ApplyGroupRule&api-version=7.1-preview.1"
    Invoke-Ado -Method PATCH -Uri $uri -Body $patch -ContentType "application/json-patch+json" | Out-Null
    Write-Ok "Group rule '$ruleName' -> Project Contributors"
}

# ---------------------------------------------------------------------------
# Identity descriptor helpers (used by area-path & repo permissions)
# ---------------------------------------------------------------------------

Add-Type -AssemblyName System.Web

function Resolve-Identity {
    <#
    Resolves a group by its "[Scope]\Name" path.
    Returns the identity object (has .id and .descriptor fields).
    #>
    param([string]$Path)

    $encoded = [System.Web.HttpUtility]::UrlEncode($Path)
    $uri     = "$VsspsUrl/_apis/identities?searchFilter=General&filterValue=$encoded&api-version=7.1"
    $result  = Invoke-Ado -Method GET -Uri $uri

    if (-not $result.value -or $result.value.Count -eq 0) {
        # Fall back to just the group name
        if ($Path -match '\\(.+)$') {
            $name    = $matches[1]
            $encoded = [System.Web.HttpUtility]::UrlEncode($name)
            $uri     = "$VsspsUrl/_apis/identities?searchFilter=General&filterValue=$encoded&api-version=7.1"
            $result  = Invoke-Ado -Method GET -Uri $uri
        }
    }
    if (-not $result.value -or $result.value.Count -eq 0) {
        throw "Identity '$Path' could not be resolved."
    }

    $match = $result.value | Where-Object {
        $_.providerDisplayName -eq $Path -or
        ($_.customDisplayName -and $_.customDisplayName -eq $Path)
    } | Select-Object -First 1
    if (-not $match) { $match = $result.value | Select-Object -First 1 }
    return $match
}

Write-Step "Resolving security groups..."
$devIdentity       = Resolve-Identity -Path $DevelopmentGroupPath
$codeReviewerIdent = Resolve-Identity -Path $CodeReviewerGroupPath
Write-Ok "Delivery group id:  $($devIdentity.id)"
Write-Ok "Code reviewer id:   $($codeReviewerIdent.id)"

# ---------------------------------------------------------------------------
# 3. Area paths + permissions
# ---------------------------------------------------------------------------

Write-Step "Creating area path structure..."

function New-Area {
    param(
        [string] $Path,   # Path relative to root; "" = root
        [string] $Name
    )
    $urlPath = if ([string]::IsNullOrEmpty($Path)) { "" } else { "/$Path" }
    $uri  = "$OrgUrl/$ProjectName/_apis/wit/classificationnodes/areas$urlPath`?api-version=7.1"
    $body = @{ name = $Name }
    try {
        $node = Invoke-Ado -Method POST -Uri $uri -Body $body -Silent
        $display = if ([string]::IsNullOrEmpty($Path)) { $Name } else { "$Path/$Name" }
        Write-Ok "Area created: $display"
        return $node
    }
    catch {
        Write-Info "Area '$Path/$Name' may exist - fetching."
        $fetchPath = if ([string]::IsNullOrEmpty($Path)) { $Name } else { "$Path/$Name" }
        return Invoke-Ado -Method GET -Uri "$OrgUrl/$ProjectName/_apis/wit/classificationnodes/areas/$fetchPath`?api-version=7.1"
    }
}

foreach ($stream in $Streams) {
    New-Area -Path "" -Name $stream | Out-Null
    foreach ($sub in $SubAreas) {
        New-Area -Path $stream -Name $sub | Out-Null
    }
}

Write-Step "Setting delivery group area permissions (project root)..."

$rootArea = Invoke-Ado -Method GET `
    -Uri "$OrgUrl/$ProjectName/_apis/wit/classificationnodes/areas?`$depth=1&api-version=7.1"

# CSS = classification structure security (area paths).
# GUID is a fixed Azure DevOps constant - look it up once from
# GET _apis/securitynamespaces (name: "CSS") and hard-code it.
$cssNamespaceId = "<GUID of the CSS security namespace>"
$rootToken      = "vstfs:///Classification/Node/$($rootArea.identifier)"

# CSS bits: Edit=2, CreateChildren=4, Delete=8 => 14
$areaAllowMask = 2 + 4 + 8

$aclBody = @{
    token                = $rootToken
    merge                = $true
    accessControlEntries = @(@{
        descriptor = $devIdentity.descriptor
        allow      = $areaAllowMask
        deny       = 0
    })
}
Invoke-Ado -Method POST `
    -Uri "$OrgUrl/_apis/accesscontrolentries/$cssNamespaceId`?api-version=7.1" `
    -Body $aclBody | Out-Null
Write-Ok "Delivery group: Edit / Create Child Nodes / Delete on '$ProjectName' area root"

# ---------------------------------------------------------------------------
# 4. Team configuration - Epics + default area with sub-areas
# ---------------------------------------------------------------------------

Write-Step "Configuring default team (Epics + sub-areas)..."

$teams       = Invoke-Ado -Method GET -Uri "$OrgUrl/_apis/projects/$projectId/teams?api-version=7.1"
$defaultTeam = $teams.value | Where-Object { $_.name -eq "$ProjectName Team" } | Select-Object -First 1
if (-not $defaultTeam) { $defaultTeam = $teams.value | Select-Object -First 1 }
if (-not $defaultTeam) { throw "Could not find a default team on '$ProjectName'." }
$teamId = $defaultTeam.id
Write-Info "Default team: $($defaultTeam.name) ($teamId)"

# Enable Epics in backlog visibility. Category ref-names below are the
# process-independent Azure DevOps defaults.
$backlogBody = @{
    backlogVisibilities = @{
        "Microsoft.EpicCategory"        = $true
        "Microsoft.RequirementCategory" = $true
        "Microsoft.FeatureCategory"     = $true
    }
}
Invoke-Ado -Method PATCH `
    -Uri "$OrgUrl/$projectId/$teamId/_apis/work/teamsettings?api-version=7.1" `
    -Body $backlogBody | Out-Null
Write-Ok "Epics enabled in backlog navigation"

# Team default area with "Include sub-areas"
$teamFieldBody = @{
    defaultValue = $ProjectName
    values       = @(@{ value = $ProjectName; includeChildren = $true })
}
Invoke-Ado -Method PATCH `
    -Uri "$OrgUrl/$projectId/$teamId/_apis/work/teamsettings/teamfieldvalues?api-version=7.1" `
    -Body $teamFieldBody | Out-Null
Write-Ok "Default area set with sub-areas included"

# ---------------------------------------------------------------------------
# 5. Repository permissions - delivery group (project-wide)
# ---------------------------------------------------------------------------

Write-Step "Setting delivery group repository permissions (project-wide)..."

# Git Repositories security namespace. Fixed Azure DevOps constant - look up
# once from GET _apis/securitynamespaces (name: "Git Repositories").
$gitNamespaceId = "<GUID of the Git Repositories security namespace>"

# Bits: CreateRepository=256, DeleteRepository=512, RenameRepository=1024,
#       RemoveOthersLocks=4096 => 5888
$repoAllowMask = 256 + 512 + 1024 + 4096
$repoToken     = "repoV2/$projectId"

$repoAclBody = @{
    token                = $repoToken
    merge                = $true
    accessControlEntries = @(@{
        descriptor = $devIdentity.descriptor
        allow      = $repoAllowMask
        deny       = 0
    })
}
Invoke-Ado -Method POST `
    -Uri "$OrgUrl/_apis/accesscontrolentries/$gitNamespaceId`?api-version=7.1" `
    -Body $repoAclBody | Out-Null
Write-Ok "Delivery group: Create / Delete / Rename Repository / Remove Others' Locks"

# ---------------------------------------------------------------------------
# 6/7. Branch policies
# ---------------------------------------------------------------------------

Write-Step "Applying branch policies..."

# Well-known policy type IDs. Fixed Azure DevOps constants - identical for every
# organisation; see the Azure DevOps "Policy Configurations" REST documentation.
$PolicyType = @{
    MinReviewers  = "fa4e907d-c16b-4a4c-9dfa-4906e5d171dd"
    WorkItemLink  = "40e92b44-2fe1-4dd6-b3d8-74a9c21d0c6e"
    Comments      = "c6a1889d-b943-4856-b76f-9e46bb6b0df2"
    MergeStrategy = "fa4e907d-c16b-4a4c-9dfa-4916e5d171ab"
    ReqReviewers  = "fd2167ab-b0be-447a-8ec8-39368250530e"
}

function New-BranchPolicy {
    param(
        [string]    $PolicyTypeId,
        [hashtable] $Settings,
        [string]    $RefName,
        [string]    $MatchKind = "Exact"
    )
    $Settings["scope"] = @(@{
        repositoryId = $null       # null = project-level (applies to every repo)
        refName      = $RefName
        matchKind    = $MatchKind
    })
    $body = @{
        isEnabled  = $true
        isBlocking = $true
        type       = @{ id = $PolicyTypeId }
        settings   = $Settings
    }
    Invoke-Ado -Method POST `
        -Uri "$OrgUrl/$projectId/_apis/policy/configurations?api-version=7.1" `
        -Body $body | Out-Null
}

function Set-BranchPoliciesForRef {
    param(
        [string] $RefName,
        [string] $MatchKind,
        [ValidateSet("RebaseFF","Squash")] [string] $MergeStrategy,
        [string] $Label
    )
    Write-Info "-> $Label ($RefName, $MatchKind)"

    New-BranchPolicy -PolicyTypeId $PolicyType.MinReviewers -RefName $RefName -MatchKind $MatchKind -Settings @{
        minimumApproverCount        = 1
        creatorVoteCounts           = $false
        allowDownvotes              = $false
        resetOnSourcePush           = $false
        requireVoteOnLastIteration  = $true
        requireVoteOnEachIteration  = $false
        resetRejectionsOnSourcePush = $false
        blockLastPusherVote         = $false
    }
    Write-Ok "  min 1 reviewer, last iteration required"

    New-BranchPolicy -PolicyTypeId $PolicyType.WorkItemLink -RefName $RefName -MatchKind $MatchKind -Settings @{}
    Write-Ok "  linked work items required"

    New-BranchPolicy -PolicyTypeId $PolicyType.Comments -RefName $RefName -MatchKind $MatchKind -Settings @{}
    Write-Ok "  comment resolution required"

    # ADO merge-strategy keys:
    #   allowNoFastForward - basic merge (creates merge commit)
    #   allowSquash        - squash merge
    #   allowRebase        - rebase and fast-forward
    #   allowRebaseMerge   - rebase with merge commit (semi-linear)
    $mergeSettings = if ($MergeStrategy -eq "RebaseFF") {
        @{ allowNoFastForward = $false; allowSquash = $false; allowRebase = $true;  allowRebaseMerge = $false }
    } else {
        @{ allowNoFastForward = $false; allowSquash = $true;  allowRebase = $false; allowRebaseMerge = $false }
    }
    New-BranchPolicy -PolicyTypeId $PolicyType.MergeStrategy -RefName $RefName -MatchKind $MatchKind -Settings $mergeSettings
    Write-Ok "  merge strategy: $MergeStrategy only"

    New-BranchPolicy -PolicyTypeId $PolicyType.ReqReviewers -RefName $RefName -MatchKind $MatchKind -Settings @{
        requiredReviewerIds = @($codeReviewerIdent.id)
        filenamePatterns    = @()
        addedFilesOnly      = $false
        message             = "Code reviewer auto-added by policy"
    }
    Write-Ok "  auto-include: $CodeReviewerGroupPath"
}

# Default branch policies
Set-BranchPoliciesForRef `
    -RefName       "refs/heads/$DefaultBranch" `
    -MatchKind     "Exact" `
    -MergeStrategy "RebaseFF" `
    -Label         "Default branch policies"

# release/* branch policies (prefix match)
Set-BranchPoliciesForRef `
    -RefName       "refs/heads/release/" `
    -MatchKind     "Prefix" `
    -MergeStrategy "Squash" `
    -Label         "release/* branch policies"

# ---------------------------------------------------------------------------
# 8. Shared Queries - sub-folders + delivery group permissions
# ---------------------------------------------------------------------------

Write-Step "Creating Shared Queries sub-folders..."

function New-QueryFolder {
    param(
        [string] $ParentPath,
        [string] $Name,
        [int]    $MaxRetries = 4
    )
    $encodedParent = [System.Web.HttpUtility]::UrlPathEncode($ParentPath)
    $encodedName   = [System.Web.HttpUtility]::UrlPathEncode($Name)
    $postUri = "$OrgUrl/$ProjectName/_apis/wit/queries/$encodedParent`?api-version=7.1"
    $getUri  = "$OrgUrl/$ProjectName/_apis/wit/queries/$encodedParent/$encodedName`?api-version=7.1"
    $body    = @{ name = $Name; isFolder = $true }

    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        try {
            Invoke-Ado -Method GET -Uri $getUri -Silent | Out-Null
            Write-Info "Query folder '$ParentPath/$Name' already exists - skipping."
            return
        } catch {}

        try {
            Invoke-Ado -Method POST -Uri $postUri -Body $body -Silent | Out-Null
            Write-Ok "Query folder created: $ParentPath/$Name"
            return
        } catch {
            if ($attempt -lt $MaxRetries) {
                Write-Info "Query folder '$ParentPath/$Name' creation failed (attempt $attempt) - retrying..."
                Start-Sleep -Seconds 2
            } else {
                Write-Warn "Could not create query folder '$ParentPath/$Name' after $MaxRetries attempts: $_"
            }
        }
    }
}

foreach ($folder in $QueryFolders) {
    New-QueryFolder -ParentPath "Shared Queries" -Name $folder | Out-Null
}

Write-Step "Setting delivery group permissions on Shared Queries..."

# Fetch the Shared Queries folder to obtain its GUID for the security token
$sharedQueriesFolder = Invoke-Ado -Method GET `
    -Uri "$OrgUrl/$ProjectName/_apis/wit/queries/Shared%20Queries?api-version=7.1"

# Work Item Query Folders security namespace. Fixed Azure DevOps constant - look
# up once from GET _apis/securitynamespaces (name: "WorkItemQueryFolders").
$witQueryNamespaceId = "<GUID of the WorkItemQueryFolders security namespace>"
# Token format: $/{projectId}/{folderId}
$queryToken = "`$/$projectId/$($sharedQueriesFolder.id)"

# Bits: Contribute=2, Delete=4, ManagePermissions=8 => 14
$queryAllowMask = 2 + 4 + 8

$queryAclBody = @{
    token                = $queryToken
    merge                = $true
    accessControlEntries = @(@{
        descriptor = $devIdentity.descriptor
        allow      = $queryAllowMask
        deny       = 0
    })
}
Invoke-Ado -Method POST `
    -Uri "$OrgUrl/_apis/accesscontrolentries/$witQueryNamespaceId`?api-version=7.1" `
    -Body $queryAclBody | Out-Null
Write-Ok "Delivery group: Contribute / Delete / Manage Permissions on 'Shared Queries'"

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

$projectUrl = "$OrgUrl/$ProjectName"

Write-Host ""
if ($script:InPipeline) {
    Write-Host "##[section]Complete"
    Write-Host "Project '$ProjectName' is fully configured."
    Write-Host "URL: $projectUrl"

    $summaryPath = Join-Path $env:AGENT_TEMPDIRECTORY "project-summary.md"
    @"
# Project Created: $ProjectName

**URL:** $projectUrl

## Configuration Applied
- Process template: $ProcessName
- Default branch: $DefaultBranch with branch policies
- Area paths: $($Streams -join ', ') each with $($SubAreas -join ', ')
- Group rules updated: $($GroupRuleNames -join ', ')
- Delivery group permissions applied to areas, repos, and Shared Queries
- Shared Queries sub-folders created: $($QueryFolders -join ', ')
- Auto-included reviewer: $CodeReviewerGroupPath
- Team configured: Epics enabled, default area includes sub-areas
"@ | Out-File -FilePath $summaryPath -Encoding utf8

    Write-Host "##vso[task.uploadsummary]$summaryPath"
    Write-Host "##vso[task.setvariable variable=ProjectUrl;isoutput=true]$projectUrl"
}
else {
    Write-Host "======================================================" -ForegroundColor Cyan
    Write-Host "  Project '$ProjectName' is fully configured." -ForegroundColor Green
    Write-Host "  URL: $projectUrl" -ForegroundColor Cyan
    Write-Host "======================================================" -ForegroundColor Cyan
}
