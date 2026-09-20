<#
.SYNOPSIS
    Creates a least-privilege local Windows account for an autonomous agent
    and collects the evidence that the account is powerless.

.DESCRIPTION
    aion-kit assumes agents run as a user that cannot write to your canon.
    This is the Windows half of that wall.

    The script creates a local user that is a member of Users and not a
    member of Administrators. It generates the password itself, so nobody
    types a secret into a console, and stores it in the caller's own profile
    directory - never inside the repository.

    It does not delete anything, does not touch other accounts, and does not
    change any ACL. Granting or denying rights on your canon is a separate,
    later step.

.PARAMETER UserName
    Name of the local account. Default: agent.

.PARAMETER Protect
    One or more paths whose ACLs are recorded in the evidence file, each with
    a verdict on whether the new account appears in them.

.PARAMETER EvidenceDir
    Where the evidence file is written. Default: .\out next to this script.

.EXAMPLE
    .\New-AgentUser.ps1 -UserName agent -Protect "C:\work\canon","$env:USERPROFILE\.claude"

.EXAMPLE
    .\New-AgentUser.ps1 -WhatIf

.NOTES
    Run from an elevated PowerShell. Creating a local account requires it.

    Two Windows limits this script works around, both found the hard way:
      * New-LocalUser rejects a Description longer than 48 characters.
      * icacls permission arguments written inline in PowerShell, such as
        "$env:USERNAME:(F)", get split and rejected. This script does not
        call icacls to set rights at all.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidatePattern('^[A-Za-z0-9._-]{1,20}$')]
    [string]$UserName = 'agent',

    [string[]]$Protect = @(),

    [string]$EvidenceDir
)

$ErrorActionPreference = 'Stop'

$SID_ADMINISTRATORS = 'S-1-5-32-544'
$SID_USERS          = 'S-1-5-32-545'

function Test-Elevated {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = [Security.Principal.WindowsPrincipal]$id
    return $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function New-StrongPassword {
    param([int]$Length = 20)

    # Ambiguous characters (l, I, O, 0, 1) are left out on purpose: this
    # password may have to be read off a screen and typed by a human.
    $lower = 'abcdefghijkmnopqrstuvwxyz'
    $upper = 'ABCDEFGHJKLMNPQRSTUVWXYZ'
    $digit = '23456789'
    $sign  = '!@#%^*-_=+'
    $all   = $lower + $upper + $digit + $sign

    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    function Pick([string]$set) {
        $b = New-Object byte[] 4
        $rng.GetBytes($b)
        return $set[[BitConverter]::ToUInt32($b, 0) % $set.Length]
    }

    # One from each class first, so the result always satisfies a default
    # complexity policy, then fill the rest and shuffle.
    $chars = @((Pick $lower), (Pick $upper), (Pick $digit), (Pick $sign))
    while ($chars.Count -lt $Length) { $chars += (Pick $all) }
    return -join ($chars | Sort-Object { Get-Random })
}

function Test-InGroup {
    param([string]$GroupSid, [string]$Name)
    try {
        $members = Get-LocalGroupMember -SID $GroupSid -ErrorAction Stop
    } catch {
        # A group holding an unresolvable SID makes this cmdlet throw.
        # That is not a reason to abort the run.
        Write-Warning "could not read group ${GroupSid}: $($_.Exception.Message)"
        return $null
    }
    return $members | Where-Object { $_.Name -like "*\$Name" }
}

# --- 1. Elevation -----------------------------------------------------------

if (-not (Test-Elevated)) {
    throw "Run this from an elevated PowerShell: creating a local account requires administrator rights."
}

# --- 2. Where evidence and secret go ---------------------------------------

if (-not $EvidenceDir) {
    $EvidenceDir = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'out'
}
if (-not (Test-Path $EvidenceDir)) {
    New-Item -ItemType Directory -Path $EvidenceDir -Force | Out-Null
}
$evidenceFile = Join-Path $EvidenceDir "$UserName-wall-evidence.txt"

# The secret never goes next to the code. Another local account cannot read
# the calling user's profile directory, which is protection enough here.
$secretDir  = Join-Path $env:USERPROFILE '.aion'
$secretFile = Join-Path $secretDir "$UserName-password.txt"

# --- 3. The account ---------------------------------------------------------

$existing = Get-LocalUser -Name $UserName -ErrorAction SilentlyContinue
if ($existing) {
    Write-Host "Account '$UserName' already exists - not recreated."
} elseif ($PSCmdlet.ShouldProcess($UserName, "create local account")) {
    $plain = New-StrongPassword

    # 48 characters is the hard limit. Keep this line short.
    $description = 'Least-privilege agent account.'

    New-LocalUser -Name $UserName `
        -Password (ConvertTo-SecureString $plain -AsPlainText -Force) `
        -FullName $UserName `
        -Description $description `
        -PasswordNeverExpires | Out-Null

    if (-not (Test-Path $secretDir)) { New-Item -ItemType Directory -Path $secretDir -Force | Out-Null }
    $plain | Out-File -FilePath $secretFile -Encoding utf8 -NoNewline

    Write-Host "Account '$UserName' created."
    Write-Host "Password written to: $secretFile"
}

# --- 4. Groups: in Users, out of Administrators -----------------------------

if (-not (Test-InGroup -GroupSid $SID_USERS -Name $UserName)) {
    if ($PSCmdlet.ShouldProcess($UserName, "add to Users")) {
        Add-LocalGroupMember -SID $SID_USERS -Member $UserName
        Write-Host "Added '$UserName' to Users."
    }
} else {
    Write-Host "'$UserName' is already in Users."
}

if (Test-InGroup -GroupSid $SID_ADMINISTRATORS -Name $UserName) {
    if ($PSCmdlet.ShouldProcess($UserName, "remove from Administrators")) {
        Remove-LocalGroupMember -SID $SID_ADMINISTRATORS -Member $UserName
        Write-Host "Removed '$UserName' from Administrators."
    }
} else {
    Write-Host "'$UserName' is not an administrator - as intended."
}

# --- 5. Evidence ------------------------------------------------------------
# From here on a stumble must not destroy the record of work already done.
$ErrorActionPreference = 'Continue'

$lines = @()
$lines += "Wall evidence for local account '$UserName'"
$lines += "Taken:   $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
$lines += "Machine: $env:COMPUTERNAME"
$lines += "Windows: $([System.Environment]::OSVersion.VersionString)"
$lines += ""
$lines += "=== Local accounts ==="
$lines += (Get-LocalUser | Select-Object Name, Enabled, Description | Format-Table -AutoSize | Out-String)
$lines += "=== Members of Administrators ==="
$lines += (Get-LocalGroupMember -SID $SID_ADMINISTRATORS -ErrorAction SilentlyContinue |
           Select-Object Name, ObjectClass | Format-Table -AutoSize | Out-String)
$lines += "=== Members of Users ==="
$lines += (Get-LocalGroupMember -SID $SID_USERS -ErrorAction SilentlyContinue |
           Select-Object Name, ObjectClass | Format-Table -AutoSize | Out-String)

if ($Protect.Count -gt 0) {
    $lines += "=== Protected paths: does '$UserName' appear in the ACL? ==="
    foreach ($path in $Protect) {
        $lines += "--- $path ---"
        if (Test-Path $path) {
            $acl = (icacls $path) -join "`r`n"
            $lines += $acl
            if ($acl -match [regex]::Escape($UserName)) {
                $lines += ">>> WARNING: '$UserName' appears in this ACL. Read it yourself."
            } else {
                $lines += ">>> '$UserName' does not appear: it holds no rights here."
            }
        } else {
            $lines += ">>> path not found"
        }
        $lines += ""
    }
}

$account  = Get-LocalUser -Name $UserName -ErrorAction SilentlyContinue
$isAdmin  = [bool](Test-InGroup -GroupSid $SID_ADMINISTRATORS -Name $UserName)
$isUser   = [bool](Test-InGroup -GroupSid $SID_USERS -Name $UserName)

$lines += "=== Verdict ==="
$lines += "account exists:        $([bool]$account)"
$lines += "account enabled:       $($account.Enabled)"
$lines += "member of Users:       $isUser     (expected True)"
$lines += "member of Admins:      $isAdmin    (expected False)"

$lines -join "`r`n" | Out-File -FilePath $evidenceFile -Encoding utf8

Write-Host ""
Write-Host "Evidence written to: $evidenceFile"
if ($isAdmin) {
    Write-Host "FAILED: '$UserName' is still an administrator."
    exit 1
}
Write-Host "OK: the wall stands."
