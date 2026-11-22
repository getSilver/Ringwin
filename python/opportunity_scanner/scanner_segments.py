"""Retire verified native RawIngress segments and resolve their stable references."""
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import stat
import subprocess
import threading
import time


HOT_LIMIT = 64 * 1024 * 1024
DISK_RESERVE = 4 * 1024 * 1024
SEGMENT = re.compile(r"market-(\d+)-(production|demo|testnet)-(\d+)-[0-9a-f]{32}\.raw")


class CaptureStorageError(OSError):
    pass


class CaptureSegments:
    def __init__(self, directory, adapters):
        self.directory = directory
        self.archive = directory / "scanner-archive"
        self.adapters = adapters
        self.lock = threading.Lock()
        self.archive_workers = ThreadPoolExecutor(max_workers=2, thread_name_prefix="scanner-archive")
        self.pending = {p: None for p in directory.glob("market-*.raw") if SEGMENT.fullmatch(p.name)}
        self.capture_faults = {}
        self.archive_faults = {}
        self.retry_at = 0

    @staticmethod
    def _source(venue, environment):
        return f"{venue}:{environment}"

    def hot_path(self, venue, environment, session):
        return self.directory / f"market-{venue}-{environment}-{session}-{secrets.token_hex(16)}.raw"

    def _hot_bytes(self):
        total = 0
        for path in self.directory.glob("market-*.raw"):
            if not SEGMENT.fullmatch(path.name):
                continue
            for item in path.rglob("*"):
                try:
                    info = item.stat()
                except FileNotFoundError:
                    # A native writer may just have replaced a temporary manifest.
                    continue
                if stat.S_ISREG(info.st_mode):
                    total += info.st_size
        return total

    def check_space(self, venue, environment, instrument):
        source = self._source(venue, environment)
        with self.lock:
            try:
                if shutil.disk_usage(self.directory).free < DISK_RESERVE:
                    raise CaptureStorageError("scanner capture disk space exhausted")
                if self._hot_bytes() >= HOT_LIMIT:
                    raise CaptureStorageError("scanner hot capture capacity exhausted")
            except OSError as error:
                self.capture_faults.setdefault(source, {})[instrument] = str(error)
                raise CaptureStorageError(str(error)) from error

    def report_capture(self, venue, environment, instrument, error=None):
        source = self._source(venue, environment)
        with self.lock:
            faults = self.capture_faults.setdefault(source, {})
            if error:
                faults[instrument] = str(error)
            else:
                faults.pop(instrument, None)
            if not faults:
                self.capture_faults.pop(source)

    def forget_capture(self, venue, instrument):
        with self.lock:
            for source in tuple(self.capture_faults):
                if source.startswith(f"{venue}:"):
                    self.capture_faults[source].pop(str(instrument), None)
                    if not self.capture_faults[source]:
                        self.capture_faults.pop(source)

    def _read(self, path, venue, session, sequence=None):
        command = [str(self.adapters[venue].executable), str(path), str(session)]
        if sequence is not None:
            command.append(str(sequence))
        try:
            result = subprocess.run(command, capture_output=True, timeout=15, check=True)
            return json.loads(result.stdout)
        except (subprocess.SubprocessError, OSError, ValueError) as error:
            detail = getattr(error, "stderr", None)
            raise CaptureStorageError("RawIngress replay failed: " +
                (detail.decode(errors="replace").splitlines()[0] if detail else str(error))) from error

    def _retire(self, path):
        venue, environment, session = SEGMENT.fullmatch(path.name).groups()
        source = self._source(venue, environment)
        destination = self.archive / f"{venue}-{environment}"
        try:
            if path.is_dir():
                if any(path.iterdir()):
                    self._read(path, int(venue), session)
                    self.archive.mkdir(exist_ok=True)
                    destination.mkdir(exist_ok=True)
                    with self.lock:
                        path.rename(destination / path.name)
                else:
                    with self.lock:
                        path.rmdir()
            if os.name == "posix" and (destination / path.name).is_dir():
                for directory in (destination, self.archive, self.directory):
                    descriptor = os.open(directory, os.O_RDONLY | os.O_DIRECTORY)
                    try:
                        os.fsync(descriptor)
                    finally:
                        os.close(descriptor)
        except OSError as error:
            with self.lock:
                self.pending[path] = source
                self.archive_faults[path] = source, str(error)
            return
        with self.lock:
            self.pending.pop(path, None)
            self.archive_faults.pop(path, None)

    def retire(self, path):
        if path:
            self.archive_workers.submit(self._retire, Path(path))

    def retry(self):
        with self.lock:
            now = time.monotonic()
            if self.pending and now >= self.retry_at:
                self.retry_at = now + 1
                # Keep retries bounded when a segment cannot be opened or verified.
                paths = list(self.pending)[:2]
                for path in paths:
                    self.pending.pop(path)
                    if int(SEGMENT.fullmatch(path.name)[1]) in self.adapters:
                        self.archive_workers.submit(self._retire, path)

    def close(self):
        self.archive_workers.shutdown(wait=True)

    def status(self):
        with self.lock:
            try:
                disk_free = shutil.disk_usage(self.directory).free
                hot_free = max(0, HOT_LIMIT - self._hot_bytes())
            except OSError:
                disk_free = hot_free = None
            faults = {source: {"archive": error} for source, error in self.archive_faults.values()}
            for source, pending in self.capture_faults.items():
                faults.setdefault(source, {})["capture"] = next(iter(pending.values()))
            return dict(disk_free_bytes=disk_free, hot_free_bytes=hot_free, faults=faults)

    def replay(self, evidence, book):
        name = Path(evidence["raw_path"]).name
        match = SEGMENT.fullmatch(name)
        if not match:
            raise CaptureStorageError("scanner capture reference")
        venue, environment, session = match.groups()
        if (venue, environment, session) != (evidence["venue"], evidence["requested_environment"],
                                             str(evidence["session"])):
            raise CaptureStorageError("scanner capture source mismatch")
        archived = self.archive / f"{venue}-{environment}" / name
        hot = self.directory / name
        args = int(venue), session, evidence["raw_sequence"]
        if archived.is_dir():
            result = self._read(archived, *args)
        else:
            try:
                result = self._read(hot, *args)
            except CaptureStorageError:
                # Retirement may move a hot segment between resolution and open.
                if not archived.is_dir():
                    raise
                result = self._read(archived, *args)
        config = json.loads(result.pop("metadata"))["configuration"]
        if (result["raw_sequence"] != evidence["raw_sequence"]
                or result["raw_sha256"] != evidence["raw_sha256"]
                or result["visible_at_ns"] != book["visible_at_ns"]
                or config["schema"] != 1
                or config["rules_version"] != book["rules_version"]
                or config["instrument"] != book["instrument"]
                or config["session"] != int(session) or config["venue"] != int(venue)
                or config["requested_environment"] != environment
                or config["environment"] != evidence["actual_environment"]):
            raise CaptureStorageError("scanner raw book identity mismatch")
        return dict(result, session=int(session), venue=venue, requested_environment=environment,
                    instrument=str(config["instrument"]), rules_version=str(config["rules_version"]),
                    source_sequence=str(book["sequence"]), visible_at_ns=str(result["visible_at_ns"]),
                    utc_ns=str(result["utc_ns"]), actual_environment=config["environment"],
                    sequence_kind=book.get("sequence_kind", "venue"),
                    capture_epoch=str(book["capture_epoch"]) if "capture_epoch" in book else None)
