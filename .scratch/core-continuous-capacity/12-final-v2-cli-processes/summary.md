# Native file process recovery

10 sequential archive rounds; 30 owned child processes; all ordinary recoveries preserve physical file bytes and full reported authority.

Before/after durable apply termination selects complete old/new shard-0 authority; the other three Owners are unchanged. This is not a cross-shard atomic transaction test. Artifact SHA mismatch rejects before launching a child.

See identity.json, workload.json, samples.jsonl, faults.jsonl, reports.json and per-command result JSON for exact commands, PIDs, file inventories and log hashes. Deterministic storage fault and authenticated schema tests are separate Zig tests.

Power loss, directory durability, resource budgets, thousand-order capacity, stress, external fencing, memory dump protection and platform production qualification remain unqualified.
