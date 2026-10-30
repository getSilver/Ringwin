"""Windows candidate process ownership and immutable installed-file permissions."""

import ctypes as c
from ctypes import wintypes as w
import os
import subprocess
import threading


kernel = c.WinDLL("kernel32", use_last_error=True)
security = c.WinDLL("advapi32", use_last_error=True)


def api(dll, name, result, *arguments):
    function = getattr(dll, name)
    function.restype, function.argtypes = result, arguments
    return function


close_handle = api(kernel, "CloseHandle", w.BOOL, w.HANDLE)
create_job = api(kernel, "CreateJobObjectW", w.HANDLE, w.LPVOID, w.LPCWSTR)
set_job = api(kernel, "SetInformationJobObject", w.BOOL, w.HANDLE, c.c_int, w.LPVOID, w.DWORD)
assign_job = api(kernel, "AssignProcessToJobObject", w.BOOL, w.HANDLE, w.HANDLE)
terminate_job = api(kernel, "TerminateJobObject", w.BOOL, w.HANDLE, w.UINT)
snapshot_threads = api(kernel, "CreateToolhelp32Snapshot", w.HANDLE, w.DWORD, w.DWORD)
thread_first = api(kernel, "Thread32First", w.BOOL, w.HANDLE, w.LPVOID)
thread_next = api(kernel, "Thread32Next", w.BOOL, w.HANDLE, w.LPVOID)
open_thread = api(kernel, "OpenThread", w.HANDLE, w.DWORD, w.BOOL, w.DWORD)
resume_thread = api(kernel, "ResumeThread", w.DWORD, w.HANDLE)


def checked(result):
    if not result:
        raise c.WinError(c.get_last_error())
    return result


def environment():
    directory = c.create_unicode_buffer(32768)
    get_directory = api(kernel, "GetWindowsDirectoryW", w.UINT, w.LPWSTR, w.UINT)
    size = checked(get_directory(directory, len(directory)))
    if size >= len(directory):
        raise OSError("Windows directory capacity exceeded")
    # Python's OS random source requires SystemRoot, never inherit PYTHONPATH/secrets.
    return {"SystemRoot": directory.value}


class BasicLimits(c.Structure):
    _fields_ = [("process_time", c.c_int64), ("job_time", c.c_int64), ("flags", w.DWORD),
                ("minimum_working_set", c.c_size_t), ("maximum_working_set", c.c_size_t),
                ("active_processes", w.DWORD), ("affinity", c.c_size_t),
                ("priority", w.DWORD), ("scheduling", w.DWORD)]


class ExtendedLimits(c.Structure):
    _fields_ = [("basic", BasicLimits), ("io_counters", c.c_uint64 * 6),
                ("process_memory", c.c_size_t), ("job_memory", c.c_size_t),
                ("peak_process_memory", c.c_size_t), ("peak_job_memory", c.c_size_t)]


class ThreadEntry(c.Structure):
    _fields_ = [("size", w.DWORD), ("usage", w.DWORD), ("thread", w.DWORD),
                ("owner", w.DWORD), ("base_priority", w.LONG),
                ("delta_priority", w.LONG), ("flags", w.DWORD)]


class Job:
    def __init__(self, memory_bytes):
        self._lock = threading.Lock()
        self.handle = checked(create_job(None, None))
        limits = ExtendedLimits()
        # Hard committed-memory limit, inherited membership, kill on backend death.
        limits.basic.flags = 0x100 | 0x2000
        limits.process_memory = memory_bytes
        try:
            checked(set_job(self.handle, 9, c.byref(limits), c.sizeof(limits)))
        except BaseException:
            self.close()
            raise

    def start(self, argv, **options):
        process = subprocess.Popen(argv, creationflags=0x4 | subprocess.CREATE_NO_WINDOW, **options)
        try:
            checked(assign_job(self.handle, int(process._handle)))
            snapshot = snapshot_threads(0x4, 0)
            if snapshot == c.c_void_p(-1).value:
                raise c.WinError(c.get_last_error())
            try:
                entry = ThreadEntry(size=c.sizeof(ThreadEntry))
                found = thread_first(snapshot, c.byref(entry))
                while found and entry.owner != process.pid:
                    found = thread_next(snapshot, c.byref(entry))
                checked(found)
                thread = checked(open_thread(0x2, False, entry.thread))
                try:
                    if resume_thread(thread) != 1:
                        raise OSError("candidate primary thread did not resume from suspension")
                finally:
                    close_handle(thread)
            finally:
                close_handle(snapshot)
            return process
        except BaseException:
            process.kill()
            process.wait(timeout=5)
            for pipe in (process.stdin, process.stdout, process.stderr):
                if pipe:
                    pipe.close()
            raise

    def terminate(self):
        with self._lock:
            if self.handle:
                checked(terminate_job(self.handle, 1))

    def close(self):
        with self._lock:
            if self.handle:
                try:
                    checked(terminate_job(self.handle, 1))
                finally:
                    close_handle(self.handle)
                    self.handle = None


def memory_enforced(python):
    job = Job(128 * 1024 * 1024)
    process = None
    try:
        process = job.start([python, "-I", "-S", "-c",
            "try:\n bytearray(256 * 1024 * 1024)\nexcept MemoryError:\n raise SystemExit(77)"],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            env=environment(), close_fds=True)
        return process.wait(timeout=5) == 77
    finally:
        job.close()
        if process is not None:
            process.wait(timeout=5)


local_free = api(kernel, "LocalFree", w.HANDLE, w.HANDLE)
get_current_process = api(kernel, "GetCurrentProcess", w.HANDLE)
open_token = api(security, "OpenProcessToken", w.BOOL, w.HANDLE, w.DWORD, c.POINTER(w.HANDLE))
get_token = api(security, "GetTokenInformation", w.BOOL, w.HANDLE, c.c_int, w.LPVOID,
                w.DWORD, c.POINTER(w.DWORD))
sid_string = api(security, "ConvertSidToStringSidW", w.BOOL, w.LPVOID, c.POINTER(w.LPWSTR))
parse_security = api(security, "ConvertStringSecurityDescriptorToSecurityDescriptorW", w.BOOL,
                     w.LPCWSTR, w.DWORD, c.POINTER(w.LPVOID), w.LPVOID)
set_security = api(security, "SetFileSecurityW", w.BOOL, w.LPCWSTR, w.DWORD, w.LPVOID)
get_security = api(security, "GetFileSecurityW", w.BOOL, w.LPCWSTR, w.DWORD, w.LPVOID,
                   w.DWORD, c.POINTER(w.DWORD))
get_dacl = api(security, "GetSecurityDescriptorDacl", w.BOOL, w.LPVOID,
               c.POINTER(w.BOOL), c.POINTER(w.LPVOID), c.POINTER(w.BOOL))
get_control = api(security, "GetSecurityDescriptorControl", w.BOOL, w.LPVOID,
                  c.POINTER(w.WORD), c.POINTER(w.DWORD))


def _owner_sid():
    token, size, sid = w.HANDLE(), w.DWORD(), w.LPWSTR()
    checked(open_token(get_current_process(), 0x8, c.byref(token)))
    try:
        get_token(token, 1, None, 0, c.byref(size))
        buffer = c.create_string_buffer(size.value)
        checked(get_token(token, 1, buffer, size, c.byref(size)))
        checked(sid_string(c.cast(buffer, c.POINTER(w.LPVOID))[0], c.byref(sid)))
        try:
            return sid.value
        finally:
            local_free(c.cast(sid, w.LPVOID))
    finally:
        close_handle(token)


OWNER_SID = _owner_sid()


def _descriptor(writable=False):
    descriptor = w.LPVOID()
    # Owner can restore its DACL for explicit maintenance, just as POSIX chmod.
    rights = "FA" if writable else "0x001600a9"
    checked(parse_security(f"D:P(A;;{rights};;;{OWNER_SID})", 1, c.byref(descriptor), None))
    return descriptor


def set_permissions(path, *, writable=False):
    descriptor = _descriptor(writable)
    try:
        checked(set_security(str(path), 0x80000004, descriptor))
        if writable:
            os.chmod(path, 0o700)
    finally:
        local_free(descriptor)


def _acl_bytes(descriptor):
    present, defaulted, acl = w.BOOL(), w.BOOL(), w.LPVOID()
    checked(get_dacl(descriptor, c.byref(present), c.byref(acl), c.byref(defaulted)))
    if not present or not acl.value:
        return None
    size = c.c_uint16.from_address(acl.value + 2).value
    return c.string_at(acl, size)


def is_sealed(path):
    if os.stat(path, follow_symlinks=False).st_file_attributes & 0x400:
        return False
    size = w.DWORD()
    get_security(str(path), 4, None, 0, c.byref(size))
    buffer = c.create_string_buffer(size.value)
    checked(get_security(str(path), 4, buffer, size, c.byref(size)))
    control, revision = w.WORD(), w.DWORD()
    checked(get_control(buffer, c.byref(control), c.byref(revision)))
    expected = _descriptor()
    try:
        return bool(control.value & 0x1000) and _acl_bytes(buffer) == _acl_bytes(expected)
    finally:
        local_free(expected)
