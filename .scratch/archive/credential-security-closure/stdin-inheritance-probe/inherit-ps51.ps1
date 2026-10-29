param([string]$Python)
$start = [Diagnostics.ProcessStartInfo]::new()
$start.FileName = $Python
$start.Arguments = '-c "import sys,hashlib;data=sys.stdin.buffer.read();print(len(data),hashlib.sha256(data).hexdigest())"' 
$start.UseShellExecute = $false
$start.RedirectStandardInput = $false
$start.RedirectStandardOutput = $true
$start.RedirectStandardError = $true
$start.CreateNoWindow = $true
$child = [Diagnostics.Process]::Start($start)
$out = $child.StandardOutput.ReadToEnd()
$err = $child.StandardError.ReadToEnd()
$child.WaitForExit()
[Console]::Out.Write($out)
[Console]::Error.Write($err)
exit $child.ExitCode
