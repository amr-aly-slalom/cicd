"""Tests for build_plugins_zip() in mwaa_s3_bootstrap.sh.

Runs it as a real subprocess (source the script, call the function) rather
than reimplementing its behavior in Python, so these tests exercise the
exact code that runs in production. Covers the two bugs this logic has
actually shipped: lost file permissions and non-deterministic output (a
bare zipfile.ZipInfo() defaulting to 0o600, and mtimes leaking into the
archive bytes, back when this was a separate Python script - see mwaa.tf
and mwaa_s3_bootstrap.sh for the full history).
"""

import os
import subprocess
import zipfile
from pathlib import Path

_SCRIPT = Path(__file__).resolve().parents[1] / "mwaa_s3_bootstrap.sh"


def _build(src: Path, dest: Path) -> None:
    # Fixed command, test-controlled paths - not untrusted input.
    args = [
        "bash",
        "-c",
        f'source "{_SCRIPT}"; build_plugins_zip "$1" "$2"',
        "bash",
        str(src),
        str(dest),
    ]
    subprocess.run(args, check=True, capture_output=True)  # noqa: S603


def _mode(zip_path: Path, name: str) -> int:
    with zipfile.ZipFile(zip_path) as zf:
        return (zf.getinfo(name).external_attr >> 16) & 0o777777


def test_preserves_source_file_permissions(tmp_path: Path) -> None:
    src = tmp_path / "plugins"
    src.mkdir()

    regular = src / "operators.py"
    regular.write_text("# regular file\n")
    regular.chmod(0o644)

    executable = src / "run.sh"
    executable.write_text("#!/bin/sh\necho hi\n")
    executable.chmod(0o755)

    dest = tmp_path / "plugins.zip"
    _build(src, dest)

    assert _mode(dest, "operators.py") == 0o100644
    assert _mode(dest, "run.sh") == 0o100755


def test_excludes_pycache_readme_gitkeep_and_tests(tmp_path: Path) -> None:
    src = tmp_path / "plugins"
    (src / "some_plugin" / "__pycache__").mkdir(parents=True)
    (src / "tests").mkdir(parents=True)
    (src / "README.md").write_text("readme")
    (src / ".gitkeep").write_text("")
    (src / "some_plugin" / "__pycache__" / "x.cpython-312.pyc").write_bytes(b"\x00")
    (src / "some_plugin" / "operators.py").write_text("op")
    (src / "tests" / "test_airflow_local_settings.py").write_text("x")
    (src / "airflow_local_settings.py").write_text("op")

    dest = tmp_path / "plugins.zip"
    _build(src, dest)

    with zipfile.ZipFile(dest) as zf:
        assert set(zf.namelist()) == {"some_plugin/operators.py", "airflow_local_settings.py"}


def test_deterministic_regardless_of_source_mtime(tmp_path: Path) -> None:
    src = tmp_path / "plugins"
    src.mkdir()
    f = src / "operators.py"
    f.write_text("op")
    f.chmod(0o644)

    dest_a = tmp_path / "a.zip"
    os.utime(f, (0, 0))
    _build(src, dest_a)

    dest_b = tmp_path / "b.zip"
    os.utime(f, (86400, 86400))
    _build(src, dest_b)

    assert dest_a.read_bytes() == dest_b.read_bytes()
