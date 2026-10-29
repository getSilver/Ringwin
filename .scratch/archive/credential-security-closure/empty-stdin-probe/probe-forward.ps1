param([string]$Python,[string]$Mode)
$ErrorActionPreference='Stop'
$original=[Console]::InputEncoding
try {
 if($Mode -eq 'utf8') {[Console]::InputEncoding=New-Object Text.UTF8Encoding($false)}
 if($Mode -eq 'ascii') {[Console]::InputEncoding=[Text.Encoding]::ASCII}
 $start=New-Object Diagnostics.ProcessStartInfo
 $start.FileName=$Python
 $start.Arguments='-c "import sys,json;data=sys.stdin.buffer.read();print(json.dumps(dict(length=len(data),prefix=data[:16].hex())))"'
 $start.UseShellExecute=$false
 $start.RedirectStandardInput=$true
 $start.RedirectStandardOutput=$true
 $start.RedirectStandardError=$true
 $start.CreateNoWindow=$true
 $child=[Diagnostics.Process]::Start($start)
 if($Mode -eq 'close') {$child.StandardInput.Close()} else {$child.StandardInput.BaseStream.Close()}
 [Console]::Out.Write($child.StandardOutput.ReadToEnd())
 [Console]::Error.Write($child.StandardError.ReadToEnd())
 $child.WaitForExit()
 if($child.ExitCode -ne 0) {exit $child.ExitCode}
} finally {[Console]::InputEncoding=$original}
$start=New-Object Diagnostics.ProcessStartInfo
$start.FileName=$Python
$start.Arguments='-c "import sys,json,hashlib;data=sys.stdin.buffer.read();print(json.dumps(dict(forward_length=len(data),sha256=hashlib.sha256(data).hexdigest())))"'
$start.UseShellExecute=$false
$start.RedirectStandardInput=$false
$start.RedirectStandardOutput=$true
$start.RedirectStandardError=$true
$start.CreateNoWindow=$true
$child=[Diagnostics.Process]::Start($start)
[Console]::Out.Write($child.StandardOutput.ReadToEnd())
[Console]::Error.Write($child.StandardError.ReadToEnd())
$child.WaitForExit()
exit $child.ExitCode
