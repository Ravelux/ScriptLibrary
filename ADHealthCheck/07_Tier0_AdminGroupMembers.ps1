# 07_Tier0_AdminGroupMembers.ps1
[CmdletBinding()]
param(
  [string]$Domain = (Get-ADDomain).DNSRoot,
  [string[]]$Tier0Groups = @(
    "Domain Admins",
    "Enterprise Admins",
    "Schema Admins",
    "Administrators",
    "Account Operators",
    "Backup Operators",
    "Server Operators",
    "Print Operators"
  ),
  [string]$ReportPath = ".\reports\07_Tier0_AdminGroupMembers.csv"
)

$ErrorActionPreference = "Stop"
Import-Module ActiveDirectory
New-Item -ItemType Directory -Path (Split-Path $ReportPath) -Force | Out-Null

$rows = foreach ($g in $Tier0Groups) {
  $grp = Get-ADGroup -Server $Domain -Identity $g -ErrorAction SilentlyContinue
  if (-not $grp) {
    [pscustomobject]@{ Group=$g; MemberSam=""; MemberDN=""; MemberType=""; Note="Group not found" }
    continue
  }

  $members = Get-ADGroupMember -Server $Domain -Identity $grp.DistinguishedName -Recursive -ErrorAction Stop
  foreach ($m in $members) {
    [pscustomobject]@{
      Group      = $g
      MemberSam  = $m.SamAccountName
      MemberDN   = $m.DistinguishedName
      MemberType = $m.ObjectClass
      Note       = ""
    }
  }
}

$rows | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $ReportPath
$rows