"""Web package loading and a bounded bridge to the node's native authority."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import queue
import shutil
import signal
import secrets
import struct
import subprocess
import tempfile
import threading
import time

import release_lifecycle
import strategy_host as bridge
import strategy_package as package
import control_plane

if os.name == "nt":
    import strategy_windows as windows


CANDIDATE_PATH = "runtime/ringwin-strategy-candidate" + (".exe" if os.name == "nt" else "")


class CandidatePipes:
    """Bounded pipe readers, including Windows anonymous pipes without select()."""

    def __init__(self, process, terminate):
        self.process, self.terminate = process, terminate
        self.output, self.stopped = queue.Queue(maxsize=4), threading.Event()
        self.busy = False
        self.errors = bytearray()
        self.threads = [threading.Thread(target=self._stdout, daemon=True),
                        threading.Thread(target=self._stderr, daemon=True)]
        try:
            for thread in self.threads:
                thread.start()
        except RuntimeError:
            self.stopped.set()
            self.terminate()
            for thread in self.threads:
                if thread.ident is not None:
                    thread.join(timeout=5)
            raise

    def _stdout(self):
        try:
            while not self.stopped.is_set():
                chunk = os.read(self.process.stdout.fileno(), 1024)
                while not self.stopped.is_set():
                    try:
                        self.output.put(chunk, timeout=0.05)
                        break
                    except queue.Full:
                        pass
                if not chunk:
                    break
        except OSError:
            pass

    def _stderr(self):
        total = 0
        try:
            while not self.stopped.is_set():
                chunk = os.read(self.process.stderr.fileno(), 1024)
                if not chunk:
                    break
                self.errors.extend(chunk[:max(0, 2048 - len(self.errors))])
                total += len(chunk)
                if total > 65536:
                    self.terminate()
                    break
        except OSError:
            pass

    def read(self, timeout):
        try:
            return self.output.get(timeout=timeout)
        except queue.Empty:
            raise package.PackageError("candidate callback or warmup budget exhausted") from None

    def write(self, data, timeout):
        finished, errors = threading.Event(), []
        def send():
            try:
                self.process.stdin.write(data)
                self.process.stdin.flush()
            except (OSError, ValueError) as error:
                errors.append(error)
            finally:
                finished.set()
        threading.Thread(target=send, daemon=True).start()
        if not finished.wait(max(0, timeout)):
            self.terminate()
            raise package.PackageError("pipe write budget exhausted")
        if errors:
            raise errors[0]

    def close(self):
        self.stopped.set()
        for thread in self.threads:
            thread.join(timeout=5)
        for pipe in (self.process.stdin, self.process.stdout, self.process.stderr):
            try:
                pipe.close()
            except OSError:
                pass  # A terminated peer can leave a buffered writer with a broken pipe.


BINDING_FIELDS = {"release_artifact", "definition_identity", "package_manifest_sha256",
                  "strategy_identity", "portfolio_identity", "decision_domain", "config_version",
                  "config_sha256", "config_json", "scopes", "risk_budget", "initialization"}


class NativeAuthority:
    """Bounded private stdio connection supplied by the embedding native node.

    The node owns the process, its authenticated control key and the single
    durable Writer. Neither a package nor HTTP can choose this connection.
    """

    def __init__(self, process, *, timeout=3):
        self.process, self.timeout = process, timeout
        self.pipes = CandidatePipes(process, process.kill)
        self.lock = threading.Lock()
        self.failed = False

    def request(self, request):
        with self.lock:
            package.require(not self.failed, "native node connection failed; recovery required")
            try:
                result = self._exchange(request)
            except (OSError, ValueError):
                self.failed = True
                try:
                    self.process.stdin.close()
                except OSError:
                    pass
                raise
            package.require("error" not in result, result.get("error", "native node rejected request"))
            return result

    def _exchange(self, request):
        data = package.canonical(request)
        package.require(len(data) <= 256 * 1024, "node request capacity exceeded")
        pending = b""
        deadline = time.monotonic() + self.timeout
        self.pipes.write(struct.pack("<I", len(data)) + data, self.timeout)
        while b"\n" not in pending:
            remaining = deadline - time.monotonic()
            package.require(remaining > 0, "native node timeout")
            chunk = self.pipes.read(remaining)
            if not chunk:
                self.pipes.threads[1].join(timeout=0.1)
                raise package.PackageError("native node disconnected: " + self.pipes.errors.decode("utf-8", "replace"))
            pending += chunk
            package.require(len(pending) <= 256 * 1024, "node response capacity exceeded")
        package.require(pending.endswith(b"\n") and pending.count(b"\n") == 1, "invalid node response framing")
        result = json.loads(pending[:-1])
        package.require(type(result) is dict, "invalid native response")
        package.require("trading_authorized" not in result or type(result["trading_authorized"]) is bool,
                        "invalid native authority state")
        return result

def memory_enforcement_available(python):
    """Probe actual kernel enforcement, not merely successful setrlimit calls."""
    if os.name == "nt":
        try:
            return windows.memory_enforced(python)
        except (OSError, subprocess.SubprocessError):
            return False
    if os.name != "posix" or shutil.which("prlimit") is None:
        return False
    probe = ("import resource\n"
             "resource.setrlimit(resource.RLIMIT_AS, (1048576, 1048576))\n"
             "try:\n bytearray(2097152)\n"
             "except MemoryError:\n raise SystemExit(77)\n")
    try:
        result = subprocess.run([python, "-I", "-S", "-c", probe],
                                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                env={"LANG": "C", "LC_ALL": "C"}, close_fds=True, timeout=3)
        return result.returncode == 77
    except (OSError, subprocess.SubprocessError):
        return False


class CandidateSource:
    """Node-owned scope and canonical QSHB input snapshot, outside Web requests.

    The embedding node supplies its sealed deployment ownership and ordered input
    batches. No HTTP field can supply or override either authority.
    """

    def __init__(self, *, shard, decision_domain, portfolio_identity, scopes, risk_budget, batches, authority=None, fencing=77,
                 placements=()):
        package.uint(shard, 32, positive=False)
        package.identity(decision_domain)
        package.identity(portfolio_identity)
        validate_scopes(scopes)
        package.uint(risk_budget)
        self.shard = shard
        package.uint(fencing)
        self.fencing = fencing
        self.scope = json.loads(package.canonical(dict(decision_domain=decision_domain,
            portfolio_identity=portfolio_identity, scopes=scopes, risk_budget=risk_budget)))
        self.batches = tuple(batches)
        self.authority = authority
        self.placements = tuple(json.loads(package.canonical(p)) for p in placements)
        for placement in self.placements:
            package.fields(placement, set(self.scope))
            package.identity(placement["decision_domain"])
            package.identity(placement["portfolio_identity"])
            validate_scopes(placement["scopes"])
            package.uint(placement["risk_budget"])

    def prepare(self, binding, checkpoint_cursor=0, *, recover=False, batches=None):
        batches = self.batches if batches is None else batches
        package.require(any(all(binding[k] == v for k, v in scope.items()) for scope in (self.scope, *self.placements)),
                        "deployment ownership or budget mismatch")
        package.require(all(type(b) is bytes and 128 <= len(b) <= 1048576 for b in batches),
                        "invalid canonical input snapshot")
        package.require(all(int.from_bytes(b[32:48], "little") == int(binding["decision_domain"], 16)
                            for b in batches), "canonical input DecisionDomain mismatch")
        # Normalize transport batching before the externally timed callbacks.
        # Coverage gaps from subscription filtering stay attached to the record.
        normalized, cursor = [], 0
        first_batch = 1
        if batches and recover:
            # Preserve actual coverage; native Repository.latest resolves unacknowledged publications.
            cursor = int.from_bytes(batches[0][80:88], "little") - 1
            first_batch = int.from_bytes(batches[0][72:80], "little")
        replay_cursor = max(cursor, checkpoint_cursor)
        for number, batch in enumerate(batches, first_batch):
            session = (int.from_bytes(batch[48:56], "little"), int.from_bytes(batch[56:60], "little"),
                       int.from_bytes(batch[64:72], "little"))
            records, last = bridge.decode_component_batch(batch, session, number, cursor)
            if not records and last > checkpoint_cursor:
                part = bytearray(batch)
                struct.pack_into("<Q", part, 72, len(normalized) + 1)
                struct.pack_into("<Q", part, 80, replay_cursor + 1)
                struct.pack_into("<I", part, 124, bridge.crc32c(part[:124] + part[128:]))
                normalized.append(bytes(part))
                replay_cursor = last
            offset = 128
            for index, record in enumerate(records):
                length = int.from_bytes(batch[offset:offset + 4], "little")
                end = last if index == len(records) - 1 else record.shard_sequence
                if end <= checkpoint_cursor:
                    offset += length
                    continue
                part = bytearray(batch[:128] + (batch[offset:offset + length] if record.shard_sequence > checkpoint_cursor else b""))
                struct.pack_into("<I", part, 12, len(part))
                struct.pack_into("<Q", part, 72, len(normalized) + 1)
                struct.pack_into("<QQ", part, 80, replay_cursor + 1, end)
                struct.pack_into("<II", part, 104, int(record.shard_sequence > checkpoint_cursor), len(part) - 128)
                struct.pack_into("<I", part, 124, bridge.crc32c(part[:124] + part[128:]))
                normalized.append(bytes(part))
                replay_cursor, offset = end, offset + length
            cursor = last
        package.require(cursor >= checkpoint_cursor, "canonical input does not reach checkpoint cursor")
        return self.shard, cursor, tuple(normalized)


def validate_scopes(scopes):
    package.require(type(scopes) is list and 0 < len(scopes) <= 256, "invalid scope capacity")
    keys = []
    for scope in scopes:
        package.fields(scope, {"venue", "exchange_account", "instrument"})
        package.require(scope["venue"] in ("okx", "binance", "bybit"), "unknown venue")
        package.identity(scope["exchange_account"])
        package.identity(scope["instrument"])
        keys.append((scope["venue"], scope["exchange_account"], scope["instrument"]))
    package.require(keys == sorted(set(keys)), "scopes must be sorted and unique")


class InstanceManager:
    def __init__(self, directory, releases, source, *, lock=None):
        self.directory = Path(directory)
        self.directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.path = self.directory / "strategy-instances.jsonl"
        self.releases, self.source = releases, source
        self._lock = lock if lock is not None else threading.RLock()
        self._candidate = lock is not None
        self._records, self._hosts, self._successor_commands = {}, {}, {}
        self._monitor_stop = threading.Event()
        self._monitor = None
        if self.path.exists():
            for line in self.path.read_bytes().splitlines():
                record = package.parse_json(line)
                self._records[record["binding"]["strategy_identity"]] = record
                self._index_successor(record)
        # Loading a record cannot restore a process or reuse Ready authority.
        for record in self._records.values():
            if record.get("successor_transition", {}).get("status") in ("draining", "committing"):
                record["successor_transition"].update(status="unknown", reason="interrupted successor cutover; reconcile native version before recovery")
            progress = record.get("successor_transition", {})
            if progress.get("status") == "completed" and progress["to_instance"] not in self._records:
                progress.update(status="unknown", reason="successor record publication incomplete")
            if record.get("config_transition", {}).get("status") in ("draining", "committing"):
                record["config_transition"].update(status="unknown", reason="interrupted cutover; reconcile native version before recovery")
            if record["status"] in ("Ready", "Recovering", "Trading"):
                record.update(status="Stopped", reason="Host absent; checkpoint recovery required", trading_authorized=False)
            self._index_successor(record)

    def _save(self, record):
        with self._lock, self.path.open("ab") as handle:
            handle.write(package.canonical(record) + b"\n")
            handle.flush()
            os.fsync(handle.fileno())
        self._records[record["binding"]["strategy_identity"]] = json.loads(package.canonical(record))
        self._index_successor(record)

    def _index_successor(self, record):
        progress = record.get("successor_transition", {})
        if "operation_identity" in progress:
            known = self._successor_commands.get(progress["operation_identity"])
            if known:
                previous = known["successor_transition"]
                if previous["status"] in ("rejected", "unknown") or (
                        previous["status"] == "completed" and known["binding"]["strategy_identity"] == previous["to_instance"]):
                    return
            self._successor_commands[progress["operation_identity"]] = json.loads(package.canonical(record))

    def view(self):
        if not self._lock.acquire(blocking=False):
            return json.loads(package.canonical(list(self._records.values())))
        try:
            for identity, host in list(self._hosts.items()):
                if identity not in self._hosts:
                    continue
                if not host.get("native") and host["process"].poll() is not None:
                    self._fail(identity, self._records[identity], "candidate Host exited")
                elif self._records[identity]["status"] == "Trading":
                    try:
                        authority = self.source.authority.request(dict(operation="status", strategy_identity=identity))
                        if not authority["trading_authorized"]:
                            self._fail(identity, self._records[identity], "native authority revoked; recovery and explicit enable required")
                        else:
                            self._records[identity]["authority"] = authority
                    except (ValueError, OSError, KeyError) as error:
                        self._fail(identity, self._records[identity], str(error))
            return json.loads(package.canonical(list(self._records.values())))
        finally:
            self._lock.release()

    def _revoke(self, identity, *, planned=False):
        if self.source.authority is not None:
            self.source.authority.request(dict(operation="restart" if planned else "fault", strategy_identity=identity))

    def _fail(self, identity, record, reason, *, planned=False):
        try:
            self._revoke(identity, planned=planned)
        except (OSError, ValueError) as error:
            reason += "; native revocation unconfirmed: " + str(error)
        finally:
            self._stop(identity)
            self._save(dict(record, status="Stopped", trading_authorized=False, reason=reason[:2048]))

    def _watch(self):
        while not self._monitor_stop.wait(0.1):
            self.view()

    def _exchange(self, identity, command):
        host = self._hosts[identity]
        if host.get("native"):
            response = self.source.authority.request(dict(operation="native_catchup", strategy_identity=identity))
            host["cursor"] = response["cursor"]
            return response, []
        self._require_idle(identity)
        host["pipes"].busy = True
        try:
            result = self._outside_lock(lambda: self._exchange_io(host, identity, command))
            package.require(self._hosts.get(identity) is host, "Host session invalidated during callback")
            return result
        finally:
            host["pipes"].busy = False

    def _require_idle(self, identity, *, allow_transition=False):
        host = self._hosts.get(identity)
        package.require(host is None or host.get("native") or not host["pipes"].busy, "Host callback in progress")
        record = self._records.get(identity, {})
        package.require(allow_transition or not any(record.get(k, {}).get("status") in ("draining", "committing")
            for k in ("config_transition", "successor_transition")), "instance transition in progress")

    def _affected_instances(self, identity):
        domain = self._records[identity]["binding"]["decision_domain"]
        return sorted(i for i in self._hosts if self._records[i]["binding"]["decision_domain"] == domain)

    def _outside_lock(self, function):
        """A slow pipe may suspend this operation, never the manager's other Hosts."""
        condition, result = threading.Condition(self._lock), []
        def execute():
            try:
                value = (True, function())
            except Exception as error:
                value = (False, error)
            with condition:
                result.append(value)
                condition.notify()
        with condition:
            threading.Thread(target=execute, daemon=True).start()
            condition.wait_for(lambda: result)
        if not result[0][0]:
            raise result[0][1]
        return result[0][1]

    def _exchange_io(self, host, identity, command):
        data = package.canonical(dict(command, strategy_identity=identity))
        package.require(len(data) <= 256 * 1024, "runtime command capacity exceeded")
        deadline = time.monotonic() + host["callback_timeout"]
        host["pipes"].write(struct.pack("<I", len(data)) + data, host["callback_timeout"])
        pending, frames = b"", []
        while True:
            remaining = deadline - time.monotonic()
            package.require(remaining > 0, "runtime callback budget exhausted")
            chunk = host["pipes"].read(remaining)
            if not chunk:
                host["pipes"].threads[1].join(timeout=0.1)
                raise package.PackageError("runtime Host exited: " + host["pipes"].errors.decode("utf-8", "replace"))
            pending += chunk
            package.require(len(pending) <= 4096, "runtime response capacity exceeded")
            while b"\n" in pending:
                line, pending = pending.split(b"\n", 1)
                response = json.loads(line)
                package.require(type(response) is dict, "invalid runtime response")
                if "output" in response:
                    package.require(len(frames) < command["max_outputs"], "runtime output capacity exceeded")
                    frames.append(response["output"])
                else:
                    package.require(not pending and response["outputs"] == len(frames), "runtime response mismatch")
                    host["cursor"] = response["cursor"]
                    if not command.get("checkpoint"):
                        host["next_input_batch"] += 1
                    return response, frames

    def control(self, identity, command, key):
        package.identity(identity)
        with self._lock:
            self.view()
            package.require(self.source.authority is not None, "native node authority unavailable")
            package.require(identity in self._hosts, "instance is not running")
            self._require_idle(identity, allow_transition=command["kind"] == "kill_switch")
            record = self._records[identity]
            package.require(command["target_identity"] == int(record["binding"]["decision_domain"], 16), "command target mismatch")
            enabling = command["kind"] == "enable_trading"
            package.require(not enabling or record["status"] == "Ready", "instance is not Ready")
            # Web deadlines use UTC seconds; canonical core events use UTC nanoseconds.
            command = dict(command, expires_at=command["expires_at"] * 1_000_000_000)
            package.uint(command["expires_at"])
            try:
                result = self.source.authority.request(dict(operation="control", strategy_identity=identity,
                    envelope=control_plane.sign_command(command, key).hex(), evidence=dict(record["evidence"],
                        cursor=self._hosts[identity]["cursor"], next_input_batch=self._hosts[identity]["next_input_batch"])))
                if enabling:
                    ack, outputs = self._exchange(identity, result["host_command"])
                    package.require(not outputs, "activation barrier produced output")
                    result = self.source.authority.request(dict(operation="applied", strategy_identity=identity,
                        cursor=ack["cursor"]))
                    package.require(result["trading_authorized"] is True, "native activation was not applied")
                    record = dict(record, status="Trading", trading_authorized=True, authority=result, reason="")
                    if self._monitor is None:
                        self._monitor_stop.clear()
                        self._monitor = threading.Thread(target=self._watch, daemon=True)
                        self._monitor.start()
                else:
                    self._stop(identity)
                    record = dict(record, status="Stopped", trading_authorized=False, authority=result, reason="explicitly disabled; checkpoint recovery required")
                    for field in ("config_transition", "successor_transition"):
                        if record.get(field, {}).get("status") in ("draining", "committing"):
                            record[field] = dict(record[field], status="unknown", reason="operator kill during cutover; reconcile native version before recovery")
                self._save(record)
                return record
            except (OSError, ValueError, KeyError, RuntimeError) as error:
                if str(error) == "ReadyBarrierMismatch":
                    self._save(dict(record, reason="Ready requires node-owned input catch-up before enabling"))
                    raise
                self._fail(identity, record, str(error))
                raise

    def deliver(self, identity, batch):
        """Node-owned input turn; HTTP requests cannot supply canonical input."""
        with self._lock:
            package.require(identity in self._hosts and self._records[identity]["status"] in ("Ready", "Trading"), "instance is not Ready or Trading")
            self._require_idle(identity)
            try:
                record, host = self._records[identity], self._hosts[identity]
                if host.get("native"):
                    self._exchange(identity, {})
                    self._save(dict(record, runtime_cursor=host["cursor"], reason="",
                        authority=self.source.authority.request(dict(operation="status", strategy_identity=identity))))
                    return []
                _, _, parts = self.source.prepare(record["binding"], host["cursor"], recover=True, batches=(batch,))
                results = []
                for part in parts:
                    command = self.source.authority.request(dict(operation="publish", strategy_identity=identity, batch=part.hex(),
                        evidence=dict(record["evidence"], cursor=host["cursor"], next_input_batch=host["next_input_batch"])))
                    _, frames = self._exchange(identity, command["host_command"])
                    package.require(record["status"] == "Trading" or not frames, "unauthorized catch-up produced output")
                    results.extend(self.source.authority.request(dict(operation="output", strategy_identity=identity, frame=frame)) for frame in frames)
                self._save(dict(record, runtime_cursor=host["cursor"], reason="",
                    authority=self.source.authority.request(dict(operation="status", strategy_identity=identity))))
                return results
            except (OSError, ValueError, KeyError):
                self._fail(identity, self._records[identity], "runtime input/output failed")
                raise

    def create(self, binding):
        with self.releases._lock, self._lock:
            package.fields(binding, BINDING_FIELDS)
            binding = json.loads(package.canonical(binding))
            for key in ("definition_identity", "strategy_identity", "portfolio_identity", "decision_domain"):
                package.identity(binding[key])
            package.digest(binding["package_manifest_sha256"])
            package.digest(binding["config_sha256"])
            package.uint(binding["config_version"])
            package.uint(binding["risk_budget"])
            validate_scopes(binding["scopes"])
            package.require(binding["initialization"] == "new", "only explicit new-instance initialization is supported")
            package.require(type(binding["config_json"]) is str, "configuration must contain canonical JSON bytes")
            config = binding["config_json"].encode("ascii")
            package.require(len(package.canonical(binding)) <= 64 * 1024, "binding capacity exceeded")
            package.parse_json(config)
            package.require(hashlib.sha256(config).hexdigest() == binding["config_sha256"], "config digest mismatch")
            self.view()
            identity = binding["strategy_identity"]
            previous = self._records.get(identity)
            if previous:
                package.require(previous["binding"] == binding, "instance identity or ConfigVersion content conflict")
                return previous
            return self._run(binding)

    def recover(self, identity):
        package.identity(identity)
        with self.releases._lock, self._lock:
            self.view()
            package.require(identity in self._records, "unknown strategy instance")
            previous = self._records[identity]
            package.require(not previous.get("superseded_by") and previous.get("successor_transition", {}).get("status") != "unknown",
                            "successor cutover forbids predecessor recovery")
            if previous.get("predecessor"):
                predecessor = self._records[previous["predecessor"]]
                package.require(predecessor.get("successor_transition", {}).get("status") == "completed",
                                "successor cutover unresolved; reconcile native version before recovery")
            package.require(previous.get("config_transition", {}).get("status") != "unknown",
                            "config cutover result unknown; reconcile native version before recovery")
            package.require(identity not in self._hosts, "stop the existing Host before recovery")
            try:
                return self._run(previous["binding"], previous)
            except (OSError, ValueError) as error:
                record = dict(previous, status="Stopped", reason=str(error)[:2048], trading_authorized=False)
                self._save(record)
                return record

    def replace(self, request):
        package.fields(request, {"operation", "strategy_identity", "expected_definition_identity",
                                 "release_artifact", "definition_identity", "package_manifest_sha256", "operation_identity"})
        package.require(request["operation"] in ("replace", "forward_rollback"), "unsupported successor operation")
        for key in ("strategy_identity", "expected_definition_identity", "definition_identity", "operation_identity"):
            package.identity(request[key])
        package.digest(request["package_manifest_sha256"])
        identity = request["strategy_identity"]
        operation = hashlib.sha256(package.canonical(request)).hexdigest()
        with self.releases._lock, self._lock:
            self.view()
            known = self._successor_commands.get(request["operation_identity"])
            if known:
                progress = known["successor_transition"]
                package.require(progress["request_sha256"] == operation, "successor command identity content conflict")
                if progress["status"] in ("validating", "draining", "committing"):
                    known["successor_transition"].update(status="unknown", reason="interrupted successor command; reconcile native version")
                return known
            package.require(len(self._successor_commands) < 1024, "successor command history capacity exceeded")
            package.require(identity in self._records, "unknown strategy instance")
            previous = self._records[identity]
            progress = previous.get("successor_transition", {})
            package.require(not previous.get("superseded_by") and progress.get("status") != "unknown", "successor cutover unresolved or already completed")
            old = previous["binding"]
            package.require(request["expected_definition_identity"] == old["definition_identity"], "current StrategyDefinition conflict")
            package.require(request["definition_identity"] != old["definition_identity"], "code replacement requires a different StrategyDefinition")
            package.require(identity in self._hosts and previous["status"] in ("Ready", "Trading"), "instance must be Ready or Trading")
            self._require_idle(identity)
            original_host = self._hosts[identity]
            package.require(self.source.authority is not None, "native node authority unavailable")
            if request["operation"] == "forward_rollback":
                package.require(any(r["binding"]["definition_identity"] == request["definition_identity"]
                                    and r["binding"]["package_manifest_sha256"] == request["package_manifest_sha256"]
                                    and r["binding"]["portfolio_identity"] == old["portfolio_identity"]
                                    for r in self._records.values()), "ForwardRollback requires a previously used definition content")
            successor = secrets.token_hex(16)
            package.identity(successor)
            package.require(successor not in self._records, "successor identity collision")
            binding = dict(old, strategy_identity=successor, **{k: request[k] for k in
                ("release_artifact", "definition_identity", "package_manifest_sha256")})
            progress = dict(method="Rebuild", kind=request["operation"], operation_identity=request["operation_identity"], request_sha256=operation, status="validating",
                            from_instance=identity, to_instance=successor, from_definition=old["definition_identity"],
                            to_definition=binding["definition_identity"], affected_scope="DecisionDomain",
                            affected_instances=self._affected_instances(identity), reason="")
            generation = max(r.get("host_generation", 0) for r in self._records.values()) + 1
            package.uint(generation)
            previous = dict(previous, successor_transition=progress, host_generation=generation)
            self._save(previous)
            candidate = InstanceManager(self.directory / (successor + "-candidate"), self.releases, self.source, lock=self._lock)
            begun = False
            try:
                result = candidate._run(binding, generation=generation)
                package.require(result["status"] == "Ready", result["reason"])
                package.require(self._hosts.get(identity) is original_host, "target Host changed during candidate validation")
                native = dict(strategy_identity=identity, successor_identity=successor,
                              current_definition_identity=old["definition_identity"],
                              current_release_identity=previous["release_identity"], current_state_schema_version=previous["state_schema_version"],
                              config_version=binding["config_version"], definition_identity=binding["definition_identity"],
                              release_identity=result["release_identity"], state_schema_version=result["state_schema_version"],
                              transition="Rebuild", operation_identity=request["operation_identity"])
                for op in ("begin_successor", "commit_successor"):
                    progress = dict(progress, status="draining" if op == "begin_successor" else "committing")
                    self._save(dict(self._records[identity], successor_transition=progress))
                    host = candidate._hosts[successor]
                    begun = True
                    try:
                        response = self.source.authority.request(dict(native, operation=op, evidence=dict(
                            host_generation=generation, cursor=host["cursor"], next_input_batch=host["next_input_batch"])))
                    except package.PackageError as error:
                        if op == "begin_successor" and str(error) in ("ReadyBarrierMismatch", "VenueReconciliationUnavailable",
                                "InvalidSuccessorTransition", "SuccessorResponsibilityOpen"):
                            begun = False
                        raise
                    self._save(dict(self._records[identity], status="Recovering", trading_authorized=False))
                    _, outputs = candidate._exchange(successor, response["host_command"])
                    package.require(not outputs, "successor catch-up produced unauthorized output")
                    package.require(self._records[identity]["status"] == "Recovering", "target stopped during successor cutover")
                snapshot, _ = candidate._exchange(successor, dict(checkpoint=True))
                package.require(self._records[identity]["status"] == "Recovering", "target stopped during successor checkpoint")
                self._stop(identity)
                progress = dict(progress, status="completed")
                self._save(dict(previous, status="Stopped", trading_authorized=False, superseded_by=successor,
                                reason="replaced by StrategySuccessor", successor_transition=progress))
                result.update(checkpoint=snapshot["checkpoint"], predecessor=identity, successor_transition=progress)
                result["evidence"].update(cursor=snapshot["cursor"], next_intent_sequence=snapshot["next_intent_sequence"],
                                          state_digest=snapshot["state_digest"], next_input_batch=candidate._hosts[successor]["next_input_batch"])
                result["recovery"].update(cursor=snapshot["cursor"], barrier=snapshot["cursor"])
                self._save(result)
                self._hosts[successor] = candidate._hosts.pop(successor)
                return result
            except (OSError, ValueError, KeyError, RuntimeError) as error:
                progress = dict(progress, status="unknown" if begun else "rejected", reason=str(error)[:2048])
                if begun:
                    self._fail(identity, dict(previous, successor_transition=progress), str(error))
                else:
                    self._save(dict(self._records[identity], successor_transition=progress))
                return self._records[identity]
            finally:
                for candidate_identity in list(candidate._hosts):
                    candidate._stop(candidate_identity)

    def update_config(self, request):
        package.fields(request, {"operation", "strategy_identity", "expected_config_version", "config_version",
                                 "config_json", "config_sha256", "transition"})
        package.identity(request["strategy_identity"])
        package.uint(request["expected_config_version"])
        package.uint(request["config_version"])
        package.digest(request["config_sha256"])
        package.require(request["transition"] in ("Keep", "Rebuild"), "unsupported transition; v1 rejects Migrate")
        package.require(type(request["config_json"]) is str, "configuration must contain canonical JSON bytes")
        config = request["config_json"].encode("ascii")
        package.parse_json(config)
        package.require(len(config) <= 64 * 1024 and hashlib.sha256(config).hexdigest() == request["config_sha256"],
                        "config digest or capacity mismatch")
        identity = request["strategy_identity"]
        operation = hashlib.sha256(package.canonical(request)).hexdigest()
        with self.releases._lock, self._lock:
            self.view()
            package.require(identity in self._records, "unknown strategy instance")
            previous = self._records[identity]
            package.require(previous.get("runtime") != "native_static", "native parameter transitions are not supported by this definition")
            if previous.get("config_transition", {}).get("request_sha256") == operation:
                return previous
            old = previous["binding"]
            versions = dict(previous.get("config_versions", {}))
            versions[str(old["config_version"])] = old["config_sha256"]
            known = versions.get(str(request["config_version"]))
            package.require(known is not None or len(versions) < 1024, "ConfigVersion history capacity exceeded")
            package.require(known is None or known == request["config_sha256"], "ConfigVersion content conflict")
            package.require(request["expected_config_version"] == old["config_version"], "current ConfigVersion conflict")
            package.require(request["config_version"] > old["config_version"], "ConfigVersion must advance")
            package.require(identity in self._hosts and previous["status"] in ("Ready", "Trading"), "instance must be Ready or Trading")
            self._require_idle(identity)
            original_host = self._hosts[identity]
            package.require(self.source.authority is not None, "native node authority unavailable")
            binding = dict(old, **{k: request[k] for k in ("config_version", "config_json", "config_sha256")})
            package.require(len(package.canonical(binding)) <= 64 * 1024, "binding capacity exceeded")
            versions[str(request["config_version"])] = request["config_sha256"]
            progress = dict(method=request["transition"], request_sha256=operation, status="validating",
                            from_version=old["config_version"], to_version=binding["config_version"],
                            affected_scope="DecisionDomain", affected_instances=self._affected_instances(identity), reason="")
            previous = dict(previous, config_versions=versions, config_transition=progress)
            # Reserve candidate session generations before a child can start.
            previous["host_generation"] = max(r.get("host_generation", 0) for r in self._records.values()) + 1
            package.uint(previous["host_generation"])
            self._save(previous)
            candidate = InstanceManager(self.directory / (identity + "-config-" + str(binding["config_version"]) + "-" + operation[:16]),
                                        self.releases, self.source, lock=self._lock)
            begun = False
            snapshot_ok = False
            try:
                snapshot, _ = self._exchange(identity, dict(checkpoint=True))
                snapshot_ok = True
                previous = dict(previous, checkpoint=snapshot["checkpoint"])
                self._save(previous)
                result = candidate._run(binding, previous, transition=request["transition"], generation=previous["host_generation"])
                package.require(result["status"] == "Ready", result["reason"])
                package.require(self._hosts.get(identity) is original_host, "target Host changed during candidate validation")
                native = dict(strategy_identity=identity, config_version=binding["config_version"],
                              current_definition_identity=old["definition_identity"],
                              current_release_identity=previous["release_identity"], current_state_schema_version=previous["state_schema_version"],
                              definition_identity=binding["definition_identity"],
                              state_schema_version=result["state_schema_version"], transition=request["transition"],
                              operation_identity=operation[:32])
                for op in ("begin_config", "commit_config"):
                    progress = dict(progress, status="draining" if op == "begin_config" else "committing")
                    self._save(dict(self._records[identity], config_transition=progress))
                    host = candidate._hosts[identity]
                    begun = True
                    try:
                        response = self.source.authority.request(dict(native, operation=op, evidence=dict(
                            host_generation=result["host_generation"], cursor=host["cursor"], next_input_batch=host["next_input_batch"])))
                    except package.PackageError as error:
                        # These native guards precede the first durable pause.
                        if op == "begin_config" and str(error) in ("ReadyBarrierMismatch", "VenueReconciliationUnavailable", "InvalidConfigTransition"):
                            begun = False
                        raise
                    self._save(dict(self._records[identity], status="Recovering", trading_authorized=False))
                    _, outputs = candidate._exchange(identity, response["host_command"])
                    package.require(not outputs, "config catch-up produced unauthorized output")
                    package.require(self._records[identity]["status"] == "Recovering", "target stopped during config cutover")
                snapshot, _ = candidate._exchange(identity, dict(checkpoint=True))
                package.require(self._records[identity]["status"] == "Recovering", "target stopped during config checkpoint")
                self._stop(identity)
                self._hosts[identity] = candidate._hosts.pop(identity)
                result.update(checkpoint=snapshot["checkpoint"], config_versions=versions,
                              config_transition=dict(progress, status="completed"))
                result["evidence"].update(cursor=snapshot["cursor"], next_intent_sequence=snapshot["next_intent_sequence"],
                                          state_digest=snapshot["state_digest"],
                                          next_input_batch=self._hosts[identity]["next_input_batch"])
                result["recovery"].update(cursor=snapshot["cursor"], barrier=snapshot["cursor"])
                self._save(result)
                return result
            except (OSError, ValueError, KeyError, RuntimeError) as error:
                progress = dict(progress, status="unknown" if begun else "rejected", reason=str(error)[:2048])
                if begun or not snapshot_ok:
                    self._fail(identity, dict(previous, config_transition=progress), str(error))
                else:
                    self._save(dict(self._records[identity], config_transition=progress))
                return self._records[identity]
            finally:
                # Uncommitted candidates never touch the old Host's native authority.
                for candidate_identity in list(candidate._hosts):
                    candidate._stop(candidate_identity)

    def _run(self, binding, previous=None, *, transition=None, generation=None):
        identity = binding["strategy_identity"]
        root, manifest, lock = self._approved_package(binding, retained=previous is not None and transition is None)
        if manifest.get("runtime") == "native_static":
            self.source.prepare(binding, batches=())
            return self._run_native(binding, root, manifest, lock, previous, generation)
        if not transition:
            peers = [i for i, h in self._hosts.items() if not h.get("native")
                     and h["request"]["binding"]["decision_domain"] == binding["decision_domain"]
                     and h["request"]["manifest"]["compatibility"] == manifest["compatibility"]]
            if peers:
                try:
                    return self._run_shared(binding, previous, root, manifest, lock, peers)
                except (OSError, ValueError, KeyError, RuntimeError) as error:
                    record = self._records.get(identity)
                    if record is not None and identity not in self._hosts:
                        self._save(dict(record, status="Stopped", trading_authorized=False, reason=str(error)[:2048]))
                    raise
        cursor = previous.get("checkpoint", {}).get("cursor", 0) if previous else 0
        shard, barrier, batches = self.source.prepare(binding, cursor, recover=previous is not None)
        release_identity = int((root / "manifest.sha256").read_text("ascii")[:16], 16)
        package.require(release_identity != 0, "invalid native release identity")
        package.require(all(int.from_bytes(b[16:32], "little") == int(manifest["compatibility"]["schema_registry"], 16)
                            for b in batches), "canonical input schema registry mismatch")
        package.require(memory_enforcement_available(str(root / lock["python_path"])),
                        "candidate hard address-space limit enforcement is unavailable or unverified; loading is unavailable")
        if generation is None:
            generation = max([r.get("host_generation", r.get("evidence", {}).get("host_generation", 0))
                              for r in self._records.values()] + [previous.get("host_generation", 0) if previous else 0]) + 1
        package.uint(generation)
        record = dict(binding=binding, status="Recovering", reason="", trading_authorized=False,
                      host_generation=generation, recovery=dict(cursor=cursor, barrier=barrier),
                      checkpoint_directory=str((self.directory / (identity + "-checkpoints")).resolve()),
                      release_identity=release_identity,
                      state_schema_version=manifest["state_schema"]["version"])
        if previous and not transition:
            for key in ("checkpoint_directory", "config_versions", "config_transition", "predecessor", "successor_transition"):
                if key in previous:
                    record[key] = previous[key]
        if previous and "checkpoint" in previous:
            record["checkpoint"] = previous["checkpoint"]
        self._save(record)
        process, temporary, job = None, None, None
        try:
            temporary = tempfile.TemporaryDirectory(prefix="candidate-", dir=self.directory)
            work = Path(temporary.name)
            request = dict(binding=binding, manifest=manifest, package_root=str(root / "strategies" / binding["definition_identity"]),
                           python=str(root / lock["python_path"]), host=str(root / lock["host_path"]),
                           generation=generation, shard=shard, fencing=self.source.fencing, barrier=barrier,
                           checkpoint_directory=record["checkpoint_directory"],
                           recover=previous is not None, checkpoint_cursor=cursor,
                           batches=[batch.hex() for batch in batches])
            if transition:
                request.update(transition=transition, previous_binding=previous["binding"],
                               source_config_version=previous["binding"]["config_version"],
                               source_checkpoint_directory=previous.get("checkpoint_directory",
                                   str((self.directory.parent / (identity + "-checkpoints")).resolve())))
            request["checkpoint"] = record.get("checkpoint")
            request["strategy_manifest"], request["checkpoint_manifest"] = package.host_manifests([request])
            record["host_placement"] = dict(members=[identity], memory_metric="process_committed_bytes" if os.name == "nt" else "process_address_space_bytes",
                memory_budget_bytes=manifest["limits"]["max_memory_bytes"],
                strategy_manifest=request["strategy_manifest"], checkpoint_manifest=request["checkpoint_manifest"])
            data = package.canonical(request)
            package.require(len(data) <= package.MAX_JSON_BYTES, "candidate request capacity exceeded")
            (work / "request.json").write_bytes(data)
            limits = manifest["limits"]
            started = time.monotonic_ns()
            argv = [str(root / CANDIDATE_PATH), str(work / "request.json")]
            options = dict(stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           cwd=work, env=windows.environment() if os.name == "nt" else {"LANG": "C", "LC_ALL": "C"},
                           close_fds=True)
            if os.name == "nt":
                job = windows.Job(limits["max_memory_bytes"])
                process = job.start(argv, **options)
            else:
                process = subprocess.Popen([shutil.which("prlimit"), "--as=" + str(limits["max_memory_bytes"]),
                                            "--fsize=" + str(max(262144, limits["max_private_state_bytes"] + 4096)),
                                            "--", *argv], start_new_session=True, **options)
            self._hosts[identity] = dict(process=process, temporary=temporary, job=job,
                                        callback_timeout=limits["max_callback_ns"] / 1e9, request=request)
            pipes = CandidatePipes(process, lambda: self._terminate(process, job))
            pipes.busy = True
            self._hosts[identity]["pipes"] = pipes
            phase_budget = limits["max_warmup_ns"]
            phase_started = started
            pending = b""
            while True:
                now = time.monotonic_ns()
                remaining = min(phase_budget - (now - phase_started), limits["max_warmup_ns"] - (now - started))
                package.require(remaining > 0, "candidate callback or warmup budget exhausted")
                chunk = self._outside_lock(lambda: pipes.read(remaining / 1e9))
                if not chunk:
                    pipes.threads[1].join(timeout=0.1)
                    reason = pipes.errors.decode("utf-8", "replace")
                    raise package.PackageError(f"candidate Host failed (exit {process.poll()}): " + reason)
                pending += chunk
                package.require(len(pending) <= 2048, "candidate result capacity exceeded")
                while b"\n" in pending:
                    line, pending = pending.split(b"\n", 1)
                    result = json.loads(line)
                    if "phase" in result:
                        phase_budget, phase_started = limits["max_callback_ns"], time.monotonic_ns()
                        if "cursor" in result:
                            record["recovery"]["cursor"] = result["cursor"]
                            self._records[identity] = json.loads(package.canonical(record))
                        continue
                    package.require(type(result) is dict and "next_input_batch" in result,
                                    "approved runtime lacks current input evidence")
                    package.uint(result["next_input_batch"])
                    package.require(result["trading_authorized"] is False
                                    and result["cursor"] == barrier, "invalid Ready evidence")
                    record.update(status="Ready", evidence=result, checkpoint=result.pop("checkpoint"), reason="")
                    self._hosts[identity].update(cursor=barrier, next_input_batch=result["next_input_batch"])
                    pipes.busy = False
                    record["recovery"]["cursor"] = barrier
                    self._save(record)
                    self._ensure_monitor()
                    return record
        except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
            if process is not None:
                self._stop(identity)
            else:
                if job is not None:
                    job.close()
                if temporary is not None:
                    temporary.cleanup()
            record.update(status="Stopped", reason=str(error)[:2048])
            self._save(record)
            return record

    def _ensure_monitor(self):
        if self._candidate:
            return
        if self._monitor is None:
            self._monitor_stop.clear()
            self._monitor = threading.Thread(target=self._watch, daemon=True)
            self._monitor.start()

    def _run_shared(self, binding, previous, root, manifest, lock, peers):
        """One approved interpreter, separate logical sessions and durable repositories."""
        identity = binding["strategy_identity"]
        package.require(os.name == "nt", "shared Host aggregate hard-memory enforcement unavailable on this platform")
        package.require(len(peers) < 16, "shared Host instance capacity exceeded")
        for member in peers:
            self._require_idle(member)
        requests, records = [], {}
        # Validate all placement before touching a running member.
        shard, barrier, batches = self.source.prepare(binding,
            previous.get("checkpoint", {}).get("cursor", 0) if previous else 0, recover=previous is not None)
        base = max([r.get("host_generation", 0) for r in self._records.values()] + [0]) + 1
        for offset, member in enumerate(sorted([*peers, identity])):
            generation = base + offset
            package.uint(generation)
            if member == identity:
                record = dict(previous or {}, binding=binding, status="Recovering", reason="", trading_authorized=False,
                    host_generation=generation, recovery=dict(cursor=previous.get("checkpoint", {}).get("cursor", 0) if previous else 0, barrier=barrier),
                    checkpoint_directory=previous["checkpoint_directory"] if previous else str((self.directory / (identity + "-checkpoints")).resolve()),
                    release_identity=int((root / "manifest.sha256").read_text("ascii")[:16], 16),
                    state_schema_version=manifest["state_schema"]["version"])
                request = dict(binding=binding, manifest=manifest,
                    package_root=str(root / "strategies" / binding["definition_identity"]),
                    python=str(root / lock["python_path"]), host=str(root / lock["host_path"]),
                    generation=generation, shard=shard, fencing=self.source.fencing, barrier=barrier,
                    checkpoint_directory=record["checkpoint_directory"], recover=previous is not None,
                    checkpoint_cursor=previous.get("checkpoint", {}).get("cursor", 0) if previous else 0,
                    batches=[b.hex() for b in batches])
            else:
                record = dict(self._records[member])
                self._approved_package(record["binding"], retained=True)
                request = dict(self._hosts[member]["request"], generation=generation, recover=True)
                request.pop("transition", None)
                request.pop("previous_binding", None)
                request.pop("source_config_version", None)
                request.pop("source_checkpoint_directory", None)
            records[member] = record
            record["host_generation"] = generation
            requests.append(request)
        for record in records.values():
            self._save(record)
        # Commit a fresh checkpoint before shared-process restart, never copy private state.
        try:
            for member in peers:
                snapshot, _ = self._exchange(member, dict(checkpoint=True))
                records[member]["checkpoint"] = snapshot["checkpoint"]
                self._save(records[member])
                request = next(r for r in requests if r["binding"]["strategy_identity"] == member)
                _, current_barrier, tail = self.source.prepare(records[member]["binding"], snapshot["cursor"], recover=True)
                request.update(checkpoint_cursor=snapshot["cursor"], barrier=current_barrier, batches=[b.hex() for b in tail])
        except (OSError, ValueError, KeyError, RuntimeError) as error:
            self._fail(member, self._records[member], "shared Host checkpoint failed: " + str(error))
            raise
        members = sorted(records)
        for request in requests:
            request["checkpoint"] = records[request["binding"]["strategy_identity"]].get("checkpoint")
        strategy_digest, checkpoint_digest = package.host_manifests(requests)
        budget = sum(r["manifest"]["limits"]["max_memory_bytes"] for r in requests)
        package.uint(budget)
        # Windows Job committed bytes cover the adapter and interpreter together.
        placement = dict(members=members, memory_metric="job_committed_bytes", memory_budget_bytes=budget,
                         strategy_manifest=strategy_digest, checkpoint_manifest=checkpoint_digest)
        for request in requests:
            request.update(python=requests[0]["python"], host=requests[0]["host"],
                           strategy_manifest=strategy_digest, checkpoint_manifest=checkpoint_digest)
        data = package.canonical(dict(instances=requests))
        package.require(len(data) <= package.MAX_JSON_BYTES, "shared Host request capacity exceeded")
        for member in peers:
            if member in self._hosts:
                self._fail(member, self._records[member], "shared Host membership changed; explicit enable required", planned=True)
        temporary = tempfile.TemporaryDirectory(prefix="shared-host-", dir=self.directory)
        process, job, pipes = None, None, None
        try:
            work = Path(temporary.name)
            (work / "request.json").write_bytes(data)
            for request in requests:
                member = request["binding"]["strategy_identity"]
                records[member].update(status="Recovering", trading_authorized=False,
                    host_generation=request["generation"], host_placement=placement, reason="shared Host restart")
                self._save(records[member])
            job = windows.Job(budget, aggregate=True)
            process = job.start([str(root / CANDIDATE_PATH), str(work / "request.json")],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                cwd=work, env=windows.environment(), close_fds=True)
            pipes = CandidatePipes(process, job.terminate)
            pipes.busy = True
            for request in requests:
                member = request["binding"]["strategy_identity"]
                self._hosts[member] = dict(process=process, temporary=temporary, job=job, pipes=pipes,
                    request=request, callback_timeout=request["manifest"]["limits"]["max_callback_ns"] / 1e9)
            pending = b""
            for request in requests:
                member = request["binding"]["strategy_identity"]
                limits = request["manifest"]["limits"]
                deadline = time.monotonic() + limits["max_warmup_ns"] / 1e9
                phase_deadline = deadline
                while True:
                    remaining = min(deadline, phase_deadline) - time.monotonic()
                    package.require(remaining > 0, "shared Host callback or warmup budget exhausted")
                    if b"\n" not in pending:
                        chunk = self._outside_lock(lambda: pipes.read(remaining))
                        if not chunk:
                            pipes.threads[1].join(timeout=0.1)
                            raise package.PackageError("shared Host exited: " + pipes.errors.decode("utf-8", "replace"))
                        pending += chunk
                        package.require(len(pending) <= 8192, "shared Host response capacity exceeded")
                        continue
                    line, pending = pending.split(b"\n", 1)
                    result = json.loads(line)
                    if "phase" in result:
                        phase_deadline = time.monotonic() + limits["max_callback_ns"] / 1e9
                        continue
                    package.require(result["strategy_identity"] == member and not result["trading_authorized"]
                                    and result["cursor"] == request["barrier"], "invalid shared Host Ready evidence")
                    record = records[member]
                    record.update(status="Ready", reason="", checkpoint=result.pop("checkpoint"), evidence=result,
                        recovery=dict(cursor=result["cursor"], barrier=result["cursor"]))
                    self._hosts[member].update(cursor=result["cursor"], next_input_batch=result["next_input_batch"])
                    self._save(record)
                    break
            pipes.busy = False
            self._ensure_monitor()
            return self._records[identity]
        except (OSError, ValueError, RuntimeError, KeyError) as error:
            for member in members:
                if member in self._hosts:
                    self._fail(member, self._records[member], str(error))
            if job is not None:
                job.close()
            if process is not None:
                process.wait(timeout=5)
                process.close()
            if pipes is not None:
                pipes.close()
            temporary.cleanup()
            for member in members:
                self._save(dict(self._records[member], status="Stopped", trading_authorized=False, reason=str(error)[:2048]))
            return self._records[identity]

    def _approved_package(self, binding, *, retained=False):
        releases = self.releases
        package.require(not releases._publication_unknown, "release publication is unknown")
        package.require(isinstance(releases.applier, release_lifecycle.FilesystemApplier), "installed release backend required")
        active = binding["release_artifact"]
        package.require(type(active) is str, "release identity must be a string")
        if retained:
            known = self._records.get(binding["strategy_identity"])
            package.require(known is not None and known["binding"] == binding and not known.get("superseded_by"),
                            "retained package requires an existing instance binding")
        else:
            package.require(active == releases.active_artifact()
                            and releases.applier.current_artifact() == active, "release is not current")
        registrations = releases._registrations()
        package.require(retained or any(p["definition_identity"] == binding["definition_identity"]
                            and p["package_manifest_sha256"] == binding["package_manifest_sha256"]
                            and p["release_artifact"] == active for p in registrations), "package is not registered")
        approved = {r["manifest_sha256"] for r in releases.records()
                    if r.get("event") == "release_activated" and r.get("artifact_id") == active}
        artifact = None
        for path in Path(releases.release_root).glob("*.json"):
            try:
                candidate = release_lifecycle.ReleaseArtifact.load(str(path), releases.release_root,
                                                                  releases.signing_key, releases.strategy_policy)
                if candidate.artifact_id == active and candidate.manifest_sha256 in approved and candidate.bundle:
                    artifact = candidate
                    break
            except (OSError, ValueError):
                continue
        package.require(artifact is not None, "authenticated approved release bytes unavailable")
        registration = next((p for p in artifact.bundle.packages if p["definition_identity"] == binding["definition_identity"]), None)
        package.require(registration is not None and registration["package_manifest_sha256"] == binding["package_manifest_sha256"],
                        "authenticated package binding mismatch")
        if registration["runtime"] == "python":
            package.require(CANDIDATE_PATH in artifact.bundle.files,
                            "approved candidate runtime adapter unavailable")
        root = Path(releases.version_root) / active
        package.require(not root.is_symlink() and sealed(root), "installed release must be immutable")
        expected = set(artifact.bundle.files) | {"strategy-registry.json", "manifest.sha256"}
        actual = set()
        for directory, directories, files in os.walk(root):
            package.require(sealed(Path(directory)), "installed release is writable")
            package.require(all(sealed(Path(directory) / name) for name in directories + files),
                            "installed release contains a writable file or link")
            for name in files:
                actual.add((Path(directory) / name).relative_to(root).as_posix())
                package.require(len(actual) <= len(expected), "undeclared installed file")
        package.require(actual == expected, "undeclared or missing installed file")
        package.require((root / "manifest.sha256").read_bytes() == (artifact.manifest_sha256 + "\n").encode("ascii"),
                        "installed release manifest identity differs")
        registry = package.canonical([dict(p, release_artifact=active) for p in artifact.bundle.packages])
        package.require((root / "strategy-registry.json").read_bytes() == registry, "installed registry differs from approved release")
        for name, content in artifact.bundle.files.items():
            path = root / name
            package.require(not any(p.is_symlink() for p in (path, *path.parents) if p != root.parent)
                            and path.is_file() and sealed(path) and path.stat().st_size == len(content)
                            and path.read_bytes() == content, "installed release differs from approved bytes")
        if registration["runtime"] == "native_static":
            build_bytes = artifact.bundle.files[registration["manifest_path"]]
            build = package.parse_json(build_bytes)
            return root, registration, dict(build_inventory=build_bytes.decode("ascii"),
                binary_sha256=hashlib.sha256(artifact.bundle.files[build["binary_path"]]).hexdigest())
        manifest = package.parse_json(artifact.bundle.files[f"strategies/{binding['definition_identity']}/manifest.json"])
        lock = package.parse_json(artifact.bundle.files["runtime-lock.json"])
        return root, manifest, lock

    def _run_native(self, binding, root, manifest, build, previous, generation):
        package.require(self.source.authority is not None, "native node authority unavailable")
        package.require(not previous or not previous.get("superseded_by"), "predecessor cannot restart")
        identity = binding["strategy_identity"]
        generation = generation or max([r.get("host_generation", 0) for r in self._records.values()] + [0]) + 1
        release_identity = int((root / "manifest.sha256").read_text("ascii")[:16], 16)
        if previous:
            self._revoke(identity)
        result = self.source.authority.request(dict(operation="native_prepare", strategy_identity=identity,
            definition_identity=binding["definition_identity"], config_json=binding["config_json"],
            config_version=binding["config_version"], release_identity=release_identity, **build))
        result["host_generation"] = generation
        self._hosts[identity] = dict(native=True, cursor=result["cursor"], next_input_batch=1)
        record = dict(binding=binding, runtime="native_static", status="Ready", reason="", trading_authorized=False,
            host_generation=generation, release_identity=release_identity, state_schema_version=manifest["state_schema"]["version"],
            recovery=dict(cursor=result["cursor"], barrier=result["cursor"]), checkpoint=result.pop("checkpoint"), evidence=result)
        self._save(record)
        return record

    @staticmethod
    def _terminate(process, job):
        if job is not None:
            job.terminate()
            return
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass

    def _stop(self, identity):
        host = self._hosts.pop(identity, None)
        if host is None:
            return
        if host.get("native"):
            return
        process = host["process"]
        for peer, other in list(self._hosts.items()):
            if other.get("process") is not process:
                continue
            reason = "shared Host stopped; recovery and explicit enable required"
            try:
                self._revoke(peer, planned=True)
            except (OSError, ValueError) as error:
                reason += "; native revocation unconfirmed: " + str(error)
            self._hosts.pop(peer)
            self._save(dict(self._records[peer], status="Stopped", trading_authorized=False, reason=reason[:2048]))
        self._terminate(process, host["job"])
        process.wait(timeout=5)
        if host["job"] is not None:
            host["job"].close()
        if "pipes" in host:
            host["pipes"].close()
        else:
            for pipe in (process.stdin, process.stdout, process.stderr):
                pipe.close()
        if os.name == "nt":
            process.close()
        host["temporary"].cleanup()

    def close(self):
        self._monitor_stop.set()
        with self._lock:
            for identity in list(self._hosts):
                self._fail(identity, self._records[identity], "candidate Host closed")
        if self._monitor is not None:
            self._monitor.join(timeout=5)
            self._monitor = None


def sealed(path):
    if os.name == "nt":
        return windows.is_sealed(path)
    return not path.is_symlink() and not path.stat().st_mode & 0o222
