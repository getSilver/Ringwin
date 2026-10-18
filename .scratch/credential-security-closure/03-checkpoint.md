# 03 implementation checkpoint

Scope: protected input/password, KEK, encode/decode/material lease ownership; restricted stream framing; Linux TTY fail closed before read; private0700 directory; Windows explicit24MiB native lock budget; random owned acceptance fixture paths.

Windows initial source iteration passed28/28; next iteration passed30/30. These phase logs are retained, not final source qualification. Public oversized-password test initially accepted a truncated prefix (03-input-red.log), then passed (03-input-green.log). Authenticated malformed payload with length129 reproduced old decode out-of-bounds panic (03-decode-red.log); restored explicit max_secret bounds in current code. Initial decode fixture itself used wrong literal buffer length; fixed harness and retained03-decode-harness-error.log separately.

Final source tests, Linux bounded/default checks and AEAD internal-workspace follow-up07 are pending. No real credentials/network/trading. The stdlib AEAD temporary/key copies are not yet protected by this checkpoint; ticket07 owns that gap.
