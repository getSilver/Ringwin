# Resolve standalone Zig sources through the common src/ module root.
function Get-ZigSourceInvocation([string[]]$ZigArguments) {
    $zig = (Get-Command zig -ErrorAction Stop).Source
    if ($ZigArguments.Count -gt 1 -and $ZigArguments[0] -in @('test', 'run', 'build-exe', 'build-obj', 'build-lib') -and $ZigArguments[1] -match '\.zig$' -and (Split-Path $ZigArguments[1] -Leaf) -notin @('main.zig', 'windows_demo_main.zig')) {
        return [pscustomobject]@{
            Executable = (Get-Command python -ErrorAction Stop).Source
            Arguments = @((Join-Path $PSScriptRoot 'zig-entry.py'), '--zig', $zig) + $ZigArguments
        }
    }
    return [pscustomobject]@{ Executable = $zig; Arguments = $ZigArguments }
}
