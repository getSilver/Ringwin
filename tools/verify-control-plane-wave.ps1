# 控制面整波自动验收入口（失败即停）。
# 覆盖: 认证/限速、CSRF 与 RiskWarning 栅栏、命令通道幂等与生效、
# 四分片定向投递、UI 投影一致性、控制面失联降级、日志重放等价。
# 成功输出: control_plane_wave_acceptance=passed

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Push-Location $root
try {
    python python\verify_control_plane_wave.py
    if ($LASTEXITCODE -ne 0) { throw "control plane wave acceptance failed ($LASTEXITCODE)" }
}
finally {
    Pop-Location
}
