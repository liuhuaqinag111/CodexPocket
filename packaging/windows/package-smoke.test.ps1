param([Parameter(Mandatory=$true)][string]$Zip)
$ErrorActionPreference='Stop'
$temp=Join-Path ([IO.Path]::GetTempPath()) ('CodexPocket ZIP Smoke '+[guid]::NewGuid().ToString())
try {
 Expand-Archive -LiteralPath $Zip -DestinationPath $temp
 $folder=(Get-ChildItem -LiteralPath $temp -Directory | Select-Object -First 1).FullName
 $node=Join-Path $folder 'runtime\node.exe'
 if((& $node --version) -ne 'v24.19.0'){throw 'Unexpected bundled Node version'}
 $cli=Join-Path $folder 'app\connector\cli.mjs'
 $data=Join-Path $temp 'User Data'
 $status=(& $node $cli init --data-dir $data | ConvertFrom-Json)
 if($LASTEXITCODE -ne 0 -or $status.running){throw 'Bundled CLI init failed'}
 $files=(Get-Content -Raw -LiteralPath (Join-Path $folder 'build-info.json') | ConvertFrom-Json).files
 if($files | Where-Object {$_ -match '\.test\.|fixtures/|app/node_modules/postject|work/'}){throw 'Non-runtime files entered the package'}
 if($files -notcontains 'THIRD_PARTY_NOTICES.md' -or $files -notcontains 'licenses/node/LICENSE'){throw 'License metadata is missing'}
 $script=Join-Path $folder 'packaging\windows\service.ps1'
 $install=Join-Path $temp 'Program Files'
 $plan=(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script -Action plan -InstallDir $install -DataDir $data | ConvertFrom-Json)
 if($LASTEXITCODE -ne 0 -or $plan.runLevel -ne 'Limited' -or $plan.logonType -ne 'Interactive'){throw 'Invalid user-service plan'}
 if(!$plan.arguments.Contains('"'+$data+'"')){throw 'Data directory is not quoted'}
 Write-Host 'PASS: Windows ZIP; bundled Node 24.19.0; CLI init; spaced paths; limited current-user plan; no tasks registered.'
} finally {
 if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Recurse -Force}
}
