param([string]$Python)
& $Python '-c' 'import sys,hashlib;data=sys.stdin.buffer.read();print(len(data),hashlib.sha256(data).hexdigest())'
exit $LASTEXITCODE
