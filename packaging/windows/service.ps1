param(
 [ValidateSet('install','start','stop','status','uninstall','plan')][string]$Action='start',
 [string]$InstallDir=(Join-Path $env:LOCALAPPDATA 'Programs\CodexPocketConnector'),
 [string]$DataDir=$(if($env:CODEX_POCKET_DATA_DIR){$env:CODEX_POCKET_DATA_DIR}else{Join-Path $env:LOCALAPPDATA 'CodexPocketConnector'})
)
$ErrorActionPreference='Stop'
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
$taskName='CodexPocketConnector-'+$identity.User.Value
$description='CodexPocket Connector managed user task'
$InstallDir=[IO.Path]::GetFullPath($InstallDir).TrimEnd('\')
$DataDir=[IO.Path]::GetFullPath($DataDir).TrimEnd('\')
if($DataDir -eq $InstallDir -or $DataDir.StartsWith($InstallDir+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Data directory must be outside the program directory.'}
$source=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$node=Join-Path $InstallDir 'runtime\node.exe'
$cli=Join-Path $InstallDir 'app\connector\cli.mjs'
$marker=Join-Path $InstallDir '.codexpocket-program'
function Quote-Argument([string]$Value) {
 '"'+($Value -replace '(\\*)"','$1$1\"' -replace '(\\+)$','$1$1')+'"'
}
$arguments=(Quote-Argument $cli)+' start --data-dir '+(Quote-Argument $DataDir)
function Assert-OwnedTask {
 $task=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
 if($task) {
  $owner=$task.Principal.UserId
  if($owner -ne $identity.User.Value -and $owner -ne $identity.Name){throw '同名任务属于其他用户，已停止操作'}
  if($task.Description -ne $description -or $task.Actions[0].Execute -ne $node -or $task.Actions[0].Arguments -ne $arguments){throw '同名任务不属于这个连接端，已停止操作'}
 }
 return $task
}
function Stop-Connector {
 $task=Assert-OwnedTask
 if(Test-Path -LiteralPath $node) {
  & $node $cli stop --data-dir $DataDir
  if($LASTEXITCODE -ne 0){throw '连接端停止失败，请打开控制面板检查后重试'}
 }
 if($task){Stop-ScheduledTask -TaskName $taskName}
}
function Start-Connector {
 $task=Assert-OwnedTask
 if(!$task){throw '请先双击 Install.cmd'}
 Start-ScheduledTask -TaskName $taskName
 for($n=0;$n -lt 30;$n++) {
  try {
   & $node $cli dashboard --data-dir $DataDir 2>$null
   if($LASTEXITCODE -eq 0){return}
  } catch {}
  Start-Sleep -Milliseconds 200
 }
 throw '控制面板尚未就绪，请稍后双击 Start.cmd'
}
if($Action -eq 'plan') {
 @{taskName=$taskName;user=$identity.Name;node=$node;arguments=$arguments;dataDir=$DataDir;installDir=$InstallDir;logonType='Interactive';runLevel='Limited'} | ConvertTo-Json
 exit
}
if((Test-Path -LiteralPath $InstallDir) -and !(Test-Path -LiteralPath $marker)){throw '安装目录不属于 CodexPocket，未修改任何文件'}
switch($Action) {
 'install' {
  Stop-Connector
  if($source -ne $InstallDir) {
   if(Test-Path -LiteralPath $InstallDir){Remove-Item -LiteralPath $InstallDir -Recurse -Force}
   New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
   Get-ChildItem -LiteralPath $source -Force | Copy-Item -Destination $InstallDir -Recurse -Force
  }
  Set-Content -LiteralPath $marker -Value 'CodexPocket Connector'
  $taskAction=New-ScheduledTaskAction -Execute $node -Argument $arguments -WorkingDirectory $InstallDir
  $trigger=New-ScheduledTaskTrigger -AtLogOn -User $identity.Name
  $principal=New-ScheduledTaskPrincipal -UserId $identity.User.Value -LogonType Interactive -RunLevel Limited
  $settings=New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
  Register-ScheduledTask -TaskName $taskName -Description $description -Action $taskAction -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
  Start-Connector
  Write-Host "Installed. User data: $DataDir"
 }
 'start' {Start-Connector}
 'status' {& $node $cli status --data-dir $DataDir;exit $LASTEXITCODE}
 'stop' {Stop-Connector;Write-Host 'Connector stopped.'}
 'uninstall' {
  Stop-Connector
  if(Assert-OwnedTask){Unregister-ScheduledTask -TaskName $taskName -Confirm:$false}
  if(Test-Path -LiteralPath $marker){Remove-Item -LiteralPath $InstallDir -Recurse -Force}
  Write-Host "Uninstalled. User data retained: $DataDir"
 }
}
