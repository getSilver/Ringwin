# Zig regression evidence boundary

- Pinned compiler: `0.17.0-dev.315+5b647b792`.
- The first `zig build test` completed with exit code 0 in this session (tool process session 4408). Its output was observed in the tool transcript, not separately captured to a file. No precise test count is claimed here.
- The common core sources, including `src/main.zig` and `src/strategy/strategy_host_lifecycle.zig`, have no changes after implementation commit `1e05071d`. Later Zig changes are confined to the separately built candidate adapter; its final Windows ReleaseSafe build and Linux cross-build succeeded.
- A second `zig build test --summary all` was started to capture a standalone log. After the user chose to submit the implementation with 04 unaccepted, this redundant long rerun was manually canceled. Its verified worktree-owned build/test process tree was terminated and cleaned up.
- [04-zig-tests.log](04-zig-tests.log) is the canceled rerun's raw exit-1 result. It is **not** a passed test run or evidence of a product assertion failure. Do not count this rerun as acceptance.
- The distinct, unresolved acceptance gap remains the complete real Host/resource suite on a Linux kernel that enforces RLIMIT_AS. Neither the first core regression pass nor a successful build closes that gap.
