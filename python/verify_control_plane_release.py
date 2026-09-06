"""Web integration acceptance for lifecycle routing and idempotent commands."""

import os
import shutil
import tempfile

import control_plane
import control_plane_web
import owner_session
import release_lifecycle
from verify_release_lifecycle import KEY, write_artifact


def expect(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"acceptance failed: {message}")


class Clock:
    def __init__(self):
        self.now = 1_700_000_000

    def __call__(self):
        return self.now


def main() -> None:
    root = tempfile.mkdtemp(prefix="ringwin-web-release-")
    try:
        manifest = write_artifact(root, "release-a", b"linux-binary", KEY)
        manager = release_lifecycle.ReleaseManager(
            root, os.path.join(root, "versions"), os.path.join(root, "release-records.jsonl"), KEY,
            candidate_check=lambda artifact: True,
            applier=release_lifecycle.MemoryApplier(),
        )
        clock = Clock()
        server = control_plane.CommandServer(KEY)
        app = control_plane_web.ControlPlaneApp(
            root, server, clock=clock,
            release_manager=manager,
            lifecycle_outbox=release_lifecycle.LifecycleOutbox(
                os.path.join(root, "outbox"), KEY),
        )
        status, setup = app.setup("correct horse battery staple")
        expect(status == 200, "Web setup")
        status, login = app.login("correct horse battery staple",
                                  owner_session.totp_at(setup["totp_secret"], clock.now),
                                  "127.0.0.1")
        expect(status == 200, "Web login")
        headers = {"Cookie": f"owner_session={login['session_token']}",
                   "X-Owner-CSRF": login["csrf_token"]}

        command = {"kind": "deploy_release", "command_identity": "1001",
                   "target_identity": "1", "target": "shard-1",
                   "manifest_path": manifest, "expected_active": None}
        status, warning = app.risk_warning(headers, command)
        expect(status == 200, "release warning")
        command.update(risk_warning_acknowledged=True,
                       risk_warning_identity=warning["warning_identity"])
        status, response = app.lifecycle(headers, command)
        expect(status == 200 and response["result"]["status"] == "activated",
               "release lifecycle route")
        status, replay = app.lifecycle(headers, command)
        expect(status == 200 and replay == response, "release route replay")
        command["manifest_path"] = os.path.join(root, "missing.json")
        status, _ = app.lifecycle(headers, command)
        expect(status == 409, "release identity conflict")

        shard_command = {"kind": "cancel_open_orders", "command_identity": "2001",
                         "target_identity": "1", "expected_version": 0}
        status, _ = app.submit_command(headers, shard_command)
        expect(status == 200, "shard command")
        status, _ = app.submit_command(headers, shard_command)
        expect(status == 200 and len(server._pending) == 1,
               "shard command replay must not enqueue twice")
        records = app.records.read_all()
        expect(all("secret" not in str(record).lower() for record in records),
               "operator records contain no secret material")
        print("control_plane_release_acceptance=passed")
    finally:
        server.close() if "server" in locals() else None
        shutil.rmtree(root, ignore_errors=True)


if __name__ == "__main__":
    main()
