<#
.SYNOPSIS
  昇腾 NPU 集群批量 SSH 助手(Windows 控制机 → EIP 节点/内网节点,Posh-SSH 4.x)。

.DESCRIPTION
  凭据文件格式(默认 Desktop\<cred-dir>\机器信息.txt):
    第 1 行 入口 EIP;第 2 行 用户名;第 3 行 密码(仅本脚本读取,不回显);第 4 行起 每行一个节点内网 IP。
  通道策略(2026-11 实测):
    - 目标为入口 EIP → Posh-SSH 直连;
    - 目标为内网 IP(10.x/172.16-31.x/192.168.x,Windows 无法直达)→ 经入口节点建 SSH 本地端口转发
      (127.0.0.1:22<末段> → 节点:22),再对隧道端口发起 SSH/SFTP,全程密码认证,无需节点间免密。
    - 全部节点使用同一套用户名/密码(实测 .28/.98 通过;其余节点连接失败会明确报错)。

.EXAMPLES
  .\cluster_ssh.ps1 -Command 'npu-smi info | head -5'                     # 全部节点
  .\cluster_ssh.ps1 -Nodes <NODE1-IP>,<ENTRY-NODE-IP> -Command 'docker ps'
  .\cluster_ssh.ps1 -Nodes <NODE1-IP> -Push .\config.env:/root/deploy/config.env
  .\cluster_ssh.ps1 -Nodes <NODE1-IP> -ScriptFile .\pd.sh -RemoteDir /root/deploy   # 上传+chmod+bash -n
  .\cluster_ssh.ps1 -Nodes <NODE1-IP> -Get /tmp/out.log:$env:TEMP\out.log
  .\cluster_ssh.ps1 -JumpCommand 'df -h /mnt/sfs_turbo'                   # 只在入口节点执行
#>
[CmdletBinding()]
param(
  [string[]]$Nodes,
  [string]$Command,
  [string]$JumpCommand,
  [string]$ScriptFile,
  [string]$Push,          # "本地路径:远程路径"
  [string]$Get,           # "远程路径:本地路径"
  [string]$CredFile = "$env:USERPROFILE\Desktop\<cred-dir>\机器信息.txt",
  [string]$RemoteDir = '/root/deploy',
  [int]$TimeoutSec = 600
)

$ErrorActionPreference = 'Stop'
if (-not (Get-Module -ListAvailable Posh-SSH)) { throw "未安装 Posh-SSH: Install-Module Posh-SSH -Scope CurrentUser" }
Import-Module Posh-SSH

# ---------- 解析凭据文件(密码不回显) ----------
if (-not (Test-Path $CredFile)) { throw "凭据文件不存在: $CredFile(格式见脚本头注释,或用 -CredFile 指定)" }
$lines = Get-Content $CredFile | Where-Object { $_.Trim() -ne '' }
if ($lines.Count -lt 4) { throw "凭据文件格式不符(第1行EIP 第2行用户名 第3行密码 第4行起节点IP)" }
$JumpIp = $lines[0].Trim(); $SshUser = $lines[1].Trim(); $SshPass = $lines[2].Trim()
$AllNodes = @($lines | Select-Object -Skip 3 | ForEach-Object { $_.Trim() })
if (-not $Nodes -or $Nodes.Count -eq 0) { $Nodes = $AllNodes }
foreach ($n in $Nodes) { if ($n -notmatch '^\d+\.\d+\.\d+\.\d+$') { throw "节点 IP 格式非法: $n" } }
$Cred = New-Object System.Management.Automation.PSCredential($SshUser, (ConvertTo-SecureString $SshPass -AsPlainText -Force))
Write-Verbose "入口=$JumpIp 用户=$SshUser(密码 ***) 节点=$($Nodes -join ',')"

# ---------- 会话管理: 入口会话懒加载 + 每节点隧道端口 ----------
$script:JumpSession = $null
function Get-JumpSession {
  if (-not $script:JumpSession) {
    foreach ($try in 1..3) {
      try { $script:JumpSession = New-SSHSession -ComputerName $JumpIp -Credential $Cred -AcceptKey -ConnectionTimeout 25 -ErrorAction Stop; break }
      catch { Start-Sleep -Seconds 5 }
    }
    if (-not $script:JumpSession) { throw "入口节点 $JumpIp 连接失败(重试 3 次)" }
  }
  return $script:JumpSession
}
function Test-PrivateIp([string]$Ip) {
  return ($Ip -match '^10\.' -or $Ip -match '^192\.168\.' -or ($Ip -match '^172\.(1[6-9]|2\d|3[01])\.'))
}
function Connect-Node {
  param([string]$Node)
  if ($Node -eq $JumpIp -or -not (Test-PrivateIp $Node)) {
    return (New-SSHSession -ComputerName $Node -Credential $Cred -AcceptKey -ConnectionTimeout 25 -ErrorAction Stop)
  }
  $js = Get-JumpSession
  $port = 22000 + [int]($Node.Split('.')[3])
  try {
    $null = New-SSHLocalPortForward -SessionId $js.SessionId -BoundHost 127.0.0.1 -BoundPort $port -RemoteAddress $Node -RemotePort 22 -ErrorAction Stop
  } catch {
    Write-Verbose "forward $port 已存在或创建失败(继续尝试连接): $($_.Exception.Message)"
  }
  Start-Sleep -Milliseconds 800
  return (New-SSHSession -ComputerName 127.0.0.1 -Port $port -Credential $Cred -AcceptKey -ConnectionTimeout 20 -ErrorAction Stop)
}

function Invoke-OnNode {
  param([string]$Node, [string]$Cmd, [int]$Timeout = 600)
  $sess = $null
  try {
    $sess = Connect-Node -Node $Node
    $r = Invoke-SSHCommand -SessionId $sess.SessionId -Command $Cmd -TimeOut $Timeout
    return @{ Mode = 'tunnel/direct'; Ok = ($r.ExitStatus -eq 0); Out = $r.Output -join "`n"; Err = $r.Error -join "`n" }
  } catch {
    return @{ Mode = 'tunnel/direct'; Ok = $false; Out = ''; Err = "$Node 连接失败: $($_.Exception.Message)" }
  } finally { if ($sess) { Remove-SSHSession -SessionId $sess.SessionId | Out-Null } }
}
function Send-ToNode {
  param([string]$Node, [string]$LocalPath, [string]$RemotePath)
  $sess = Connect-Node -Node $Node
  try {
    $dir = [System.IO.Path]::GetDirectoryName($RemotePath).Replace('\', '/')
    $tmp = '/tmp/_cls_upload'
    Invoke-SSHCommand -SessionId $sess.SessionId -Command "mkdir -p '$dir' '$tmp'" -TimeOut 30 | Out-Null
    $sftp = $null
    try {
      $sftp = New-SFTPSession -ComputerName $sess.Connection.Host -Port $sess.Connection.Port -Credential $Cred -AcceptKey -ErrorAction Stop
    } catch {
      Write-Host "[!] $Node SFTP 建立失败: $($_.Exception.Message)" -ForegroundColor Yellow
      return $false
    }
    try {
      # Set-SFTPItem 上传到临时目录再 mv 到目标(目标可能是文件名)
      Set-SFTPItem -SessionId $sftp.SessionId -Path $LocalPath -Destination $tmp -Force
      $leaf = Split-Path $LocalPath -Leaf
      Invoke-SSHCommand -SessionId $sess.SessionId -Command "mv '/tmp/_cls_upload/$leaf' '$RemotePath'" -TimeOut 60 | Out-Null
      return $true
    } finally { if ($sftp) { Remove-SFTPSession -SessionId $sftp.SessionId | Out-Null } }
  } finally { Remove-SSHSession -SessionId $sess.SessionId | Out-Null }
}
function Get-FromNode {
  param([string]$Node, [string]$RemotePath, [string]$LocalPath)
  $sess = Connect-Node -Node $Node
  try {
    $sftp = New-SFTPSession -ComputerName $sess.Connection.Host -Port $sess.Connection.Port -Credential $Cred -AcceptKey -ErrorAction Stop
    try {
      Get-SFTPItem -SessionId $sftp.SessionId -Path $RemotePath -Destination $LocalPath -Force
      return $true
    } finally { Remove-SFTPSession -SessionId $sftp.SessionId | Out-Null }
  } catch {
    Write-Host "[!] $Node SFTP 取文件失败: $($_.Exception.Message)" -ForegroundColor Yellow
    return $false
  } finally { Remove-SSHSession -SessionId $sess.SessionId | Out-Null }
}

# ---------- 只在入口节点执行 ----------
if ($JumpCommand) {
  $js = Get-JumpSession
  $r = Invoke-SSHCommand -SessionId $js.SessionId -Command $JumpCommand -TimeOut $TimeoutSec
  Write-Host "===== [entry $JumpIp] exit=$($r.ExitStatus) ====="
  if ($r.Output) { $r.Output | Write-Host }
  if ($r.Error) { Write-Host $r.Error -ForegroundColor Yellow }
}

# ---------- 文件传输 ----------
if ($Push) {
  $parts = $Push.Split(':', 2)
  if ($parts.Count -ne 2) { throw '-Push 格式: 本地路径:远程路径' }
  foreach ($n in $Nodes) {
    $okp = Send-ToNode -Node $n -LocalPath $parts[0] -RemotePath $parts[1]
    Write-Host ("[{0}] push {1} -> {2}: {3}" -f $n, $parts[0], $parts[1], $(if ($okp) {'OK'} else {'FAIL'}))
  }
}
if ($Get) {
  $parts = $Get.Split(':', 2)
  if ($parts.Count -ne 2) { throw '-Get 格式: 远程路径:本地路径' }
  foreach ($n in $Nodes) {
    $okp = Get-FromNode -Node $n -RemotePath $parts[0] -LocalPath $parts[1]
    Write-Host ("[{0}] get {1} -> {2}: {3}" -f $n, $parts[0], $parts[1], $(if ($okp) {'OK'} else {'FAIL'}))
  }
}

# ---------- 上传脚本并做 bash 语法检查 ----------
if ($ScriptFile) {
  if (-not (Test-Path $ScriptFile)) { throw "本地脚本不存在: $ScriptFile" }
  $leaf = Split-Path $ScriptFile -Leaf
  foreach ($n in $Nodes) {
    $okp = Send-ToNode -Node $n -LocalPath $ScriptFile -RemotePath "$RemoteDir/$leaf"
    if (-not $okp) { Write-Host "[$n] 上传失败,跳过"; continue }
    $res = Invoke-OnNode -Node $n -Cmd "chmod +x '$RemoteDir/$leaf' && bash -n '$RemoteDir/$leaf' && echo SYNTAX_OK"
    Write-Host ("[{0}] {1}: {2}" -f $n, $leaf, $(if ($res.Ok -and $res.Out -match 'SYNTAX_OK') {'上传+语法检查 OK'} else {"检查失败: $($res.Err)"}))
  }
}

# ---------- 批量命令 ----------
if ($Command) {
  $fails = 0
  foreach ($n in $Nodes) {
    $res = Invoke-OnNode -Node $n -Cmd $Command -Timeout $TimeoutSec
    Write-Host ""
    Write-Host ("===== [{0}] exit={1} =====" -f $n, $(if ($res.Ok) {0} else {1}))
    if ($res.Out) { Write-Host $res.Out }
    if ($res.Err) { Write-Host $res.Err -ForegroundColor Yellow }
    if (-not $res.Ok) { $fails++ }
  }
  if ($fails -gt 0) { Write-Host "`n$fails/$($Nodes.Count) 台执行失败" -ForegroundColor Yellow; exit 1 }
}

if (-not ($Command -or $JumpCommand -or $Push -or $Get -or $ScriptFile)) {
  Write-Host "未指定操作。示例: .\cluster_ssh.ps1 -Command 'npu-smi info | head -5'"
}
if ($script:JumpSession) { Remove-SSHSession -SessionId $script:JumpSession.SessionId | Out-Null }
