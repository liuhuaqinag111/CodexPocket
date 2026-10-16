param([string]$RuntimeNode='node')
$ErrorActionPreference='Stop'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'service.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw ($errors | Out-String)}
foreach($function in $ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$false)) {
 Invoke-Expression $function.Extent.Text
}
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
$taskName='CodexPocketConnector-'+$identity.User.Value
$description='CodexPocket Connector managed user task'
$node='C:\User With Spaces\runtime\node.exe'
$arguments='"C:\User With Spaces\app\connector\cli.mjs" start --data-dir "C:\User Data"'
$script:fixture=[pscustomobject]@{Principal=[pscustomobject]@{UserId=$identity.User.Value};Description=$description;Actions=@([pscustomobject]@{Execute=$node;Arguments=$arguments})}
function Get-ScheduledTask {param($TaskName) return $script:fixture}
if(!(Assert-OwnedTask)){throw 'Owned task should be recognized'}
$script:fixture.Principal.UserId='S-1-5-21-other-user'
$rejected=$false;try{Assert-OwnedTask}catch{$rejected=$true}
if(!$rejected){throw 'A foreign task was accepted'}
$script:fixture.Principal.UserId=$identity.User.Value
$script:fixture.Actions[0].Execute='C:\Unrelated\node.exe'
$rejected=$false;try{Assert-OwnedTask}catch{$rejected=$true}
if(!$rejected){throw 'An unrelated task was accepted'}
foreach($value in @('C:\Space & Name\end\','argument with "quotes"')) {
 $psi=New-Object Diagnostics.ProcessStartInfo
 $psi.FileName=$RuntimeNode
 $psi.Arguments='-e '+(Quote-Argument 'console.log(JSON.stringify(process.argv.slice(1)))')+' '+(Quote-Argument $value)
 $psi.UseShellExecute=$false;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
 $p=[Diagnostics.Process]::Start($psi);$output=$p.StandardOutput.ReadToEnd();$p.WaitForExit()
 if($p.ExitCode -ne 0){throw 'Node argument roundtrip failed'}
 $actual=@($output | ConvertFrom-Json)
 if($actual.Count -ne 1 -or $actual[0] -cne $value){throw 'Argument quoting did not roundtrip'}
}
Write-Host 'PASS: PowerShell parser; own-task checks; foreign-task refusal; spaced and quoted argument roundtrips. No tasks were registered.'
