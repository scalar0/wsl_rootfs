import os
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]


@pytest.mark.parametrize("recipe", ["check", "check-nix", "update"])
def test_nix_recipes_enable_features(tmp_path, recipe):
    binary = tmp_path / "nix"
    binary.write_text(
        "#!/bin/sh\n"
        'printf "%s\\n" "$@" >> "$NIX_TEST_LOG"\n'
        '[ "$1" = "--extra-experimental-features" ] || exit 42\n'
        '[ "$2" = "nix-command flakes" ] || exit 42\n'
        '[ "$NIX_CONFIG" = "experimental-features =" ] || exit 43\n'
    )
    binary.chmod(0o755)
    log = tmp_path / "arguments"
    environment = {
        **os.environ,
        "PATH": f"{tmp_path}:{os.environ['PATH']}",
        "NIX_CONFIG": "experimental-features =",
        "NIX_TEST_LOG": str(log),
    }
    repository = tmp_path / "repository"
    repository.mkdir()
    shutil.copy2(ROOT / "Justfile", repository / "Justfile")
    shutil.copytree(ROOT / "scripts", repository / "scripts")
    (repository / "nix").mkdir()
    lock = repository / "nix/flake.lock"
    shutil.copy2(ROOT / "nix/flake.lock", lock)
    original_lock = lock.read_bytes()
    result = subprocess.run(
        ["just", "--justfile", str(repository / "Justfile"), recipe],
        env=environment,
        capture_output=True,
        text=True,
        timeout=15,
    )
    assert lock.read_bytes() == original_lock
    assert result.returncode == 0, result.stderr
    arguments = log.read_text().splitlines()
    expected_commands = {
        "check": ["develop"],
        "check-nix": ["flake"],
        "update": ["flake", "flake"],
    }
    actual_commands = [
        arguments[index + 2]
        for index, value in enumerate(arguments)
        if value == "--extra-experimental-features"
    ]
    assert actual_commands == expected_commands[recipe]
