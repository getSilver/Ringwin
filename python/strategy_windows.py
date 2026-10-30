"""Windows candidate process ownership and immutable installed-file permissions."""

import ctypes as c
from ctypes import wintypes as w
import os
import math
import msvcrt
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
terminate_job = api(kernel, "TerminateJobObject", w.BOOL, w.HANDLE, w.UINT)
resume_thread = api(kernel, "ResumeThread", w.DWORD, w.HANDLE)
initialize_attributes = api(kernel, "InitializeProcThreadAttributeList", w.BOOL,
                            w.LPVOID, w.DWORD, w.DWORD, c.POINTER(c.c_size_t))
update_attribute = api(kernel, "UpdateProcThreadAttribute", w.BOOL, w.LPVOID, w.DWORD,
                       c.c_size_t, w.LPVOID, c.c_size_t, w.LPVOID, w.LPVOID)
delete_attributes = api(kernel, "DeleteProcThreadAttributeList", None, w.LPVOID)
create_process = api(kernel, "CreateProcessW", w.BOOL, w.LPCWSTR, w.LPWSTR, w.LPVOID,
                     w.LPVOID, w.BOOL, w.DWORD, w.LPVOID, w.LPCWSTR, w.LPVOID, w.LPVOID)
wait_process = api(kernel, "WaitForSingleObject", w.DWORD, w.HANDLE, w.DWORD)
exit_code = api(kernel, "GetExitCodeProcess", w.BOOL, w.HANDLE, c.POINTER(w.DWORD))
kill_process = api(kernel, "TerminateProcess", w.BOOL, w.HANDLE, w.UINT)


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


class StartupInfo(c.Structure):
    _fields_ = [("size", w.DWORD), ("reserved", w.LPWSTR), ("desktop", w.LPWSTR),
                ("title", w.LPWSTR), ("x", w.DWORD), ("y", w.DWORD),
                ("width", w.DWORD), ("height", w.DWORD), ("columns", w.DWORD),
                ("rows", w.DWORD), ("fill", w.DWORD), ("flags", w.DWORD),
                ("show", w.WORD), ("reserved_size", w.WORD), ("reserved_data", w.LPVOID),
                ("stdin", w.HANDLE), ("stdout", w.HANDLE), ("stderr", w.HANDLE)]


class StartupInfoEx(c.Structure):
    _fields_ = [("startup", StartupInfo), ("attributes", w.LPVOID)]


class ProcessInfo(c.Structure):
    _fields_ = [("process", w.HANDLE), ("thread", w.HANDLE),
                ("pid", w.DWORD), ("tid", w.DWORD)]


class Process:
    """Only the pipe/poll/wait operations used by the candidate backend."""

    def __init__(self, argv):
        self.args, self.handle, self.pid, self.returncode = argv, None, None, None
        self.stdin = self.stdout = self.stderr = None

    def poll(self):
        try:
            return self.wait(timeout=0)
        except subprocess.TimeoutExpired:
            return None

    def wait(self, timeout=None):
        if self.returncode is not None:
            return self.returncode
        milliseconds = 0xffffffff if timeout is None else min(0xfffffffe, math.ceil(max(0, timeout) * 1000))
        status = wait_process(self.handle, milliseconds)
        if status == 258:
            raise subprocess.TimeoutExpired(self.args, timeout)
        if status != 0:
            raise c.WinError(c.get_last_error())
        code = w.DWORD()
        checked(exit_code(self.handle, c.byref(code)))
        self.returncode = code.value
        return self.returncode

    def kill(self):
        if self.poll() is None:
            checked(kill_process(self.handle, 1))

    def close(self):
        for pipe in (self.stdin, self.stdout, self.stderr):
            if pipe is not None:
                pipe.close()
        if self.handle:
            close_handle(self.handle)
            self.handle = None


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

    def start(self, argv, *, stdin, stdout, stderr, env, close_fds, cwd=None):
        if not close_fds:
            raise ValueError("candidate requires an explicit inherited handle list")
        process, child_fds, handles = Process(argv), [], []
        attributes = None
        try:
            for name, value in (("stdin", stdin), ("stdout", stdout), ("stderr", stderr)):
                if value == subprocess.PIPE:
                    read_fd, write_fd = os.pipe()
                    child_fd, parent_fd = (read_fd, write_fd) if name == "stdin" else (write_fd, read_fd)
                    child_fds.append(child_fd)
                    setattr(process, name, os.fdopen(parent_fd, "wb" if name == "stdin" else "rb", buffering=0))
                elif value == subprocess.DEVNULL:
                    child_fd = os.open(os.devnull, os.O_RDONLY if name == "stdin" else os.O_WRONLY)
                    child_fds.append(child_fd)
                else:
                    raise ValueError("candidate stdio must use a pipe or DEVNULL")
                handle = msvcrt.get_osfhandle(child_fd)
                os.set_handle_inheritable(handle, True)
                handles.append(handle)
            size = c.c_size_t()
            initialize_attributes(None, 2, 0, c.byref(size))
            storage = c.create_string_buffer(size.value)
            checked(initialize_attributes(storage, 2, 0, c.byref(size)))
            attributes = storage
            job_list = (w.HANDLE * 1)(self.handle)
            handle_list = (w.HANDLE * 3)(*handles)
            # PROC_THREAD_ATTRIBUTE_JOB_LIST binds ownership inside CreateProcess.
            checked(update_attribute(attributes, 0, 0x2000d, job_list, c.sizeof(job_list), None, None))
            checked(update_attribute(attributes, 0, 0x20002, handle_list, c.sizeof(handle_list), None, None))
            startup = StartupInfoEx()
            startup.startup.size, startup.startup.flags = c.sizeof(startup), 0x100
            startup.startup.stdin, startup.startup.stdout, startup.startup.stderr = handles
            startup.attributes = c.cast(attributes, w.LPVOID)
            command = c.create_unicode_buffer(subprocess.list2cmdline(argv))
            environment_block = c.create_unicode_buffer("\0".join(f"{key}={value}" for key, value in sorted(env.items())) + "\0\0")
            info = ProcessInfo()
            flags = 0x4 | 0x400 | 0x80000 | subprocess.CREATE_NO_WINDOW
            checked(create_process(argv[0], command, None, None, True, flags,
                                   environment_block, str(cwd) if cwd is not None else None,
                                   c.byref(startup), c.byref(info)))
            process.handle, process.pid = info.process, info.pid
            try:
                if resume_thread(info.thread) != 1:
                    raise OSError("candidate primary thread did not resume from suspension")
            finally:
                close_handle(info.thread)
            return process
        except BaseException:
            if process.handle:
                self.terminate()
                process.wait(timeout=5)
            process.close()
            raise
        finally:
            if attributes is not None:
                delete_attributes(attributes)
            for descriptor in child_fds:
                os.close(descriptor)

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
            process.close()


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
