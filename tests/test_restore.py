import hashlib
import io
import json
import os
import subprocess
import tarfile
from pathlib import Path

import pytest
import wsl_rootfs as restore


@pytest.fixture
def profile():
    value = restore.load_profile()
    value["reserveBytes"] = 0
    return value


@pytest.fixture(autouse=True)
def git_environment(monkeypatch, tmp_path):
    monkeypatch.setenv("GIT_CONFIG_GLOBAL", os.devnull)
    monkeypatch.setenv("GIT_CONFIG_NOSYSTEM", "1")
    temporary = tmp_path / "temporary"
    temporary.mkdir()
    monkeypatch.setenv("TMPDIR", str(temporary))


def command(*args, cwd=None):
    return (
        subprocess.run([str(arg) for arg in args], cwd=cwd, check=True, capture_output=True)
        .stdout.decode()
        .strip()
    )


@pytest.fixture
def repository(tmp_path):
    remote = tmp_path / "remote.git"
    work = tmp_path / "work"
    command("git", "init", "--bare", "--quiet", remote)
    command("git", "init", "--quiet", work)
    (work / "source.txt").write_text("source\n")
    command("git", "add", ".", cwd=work)
    commit(work)
    command("git", "remote", "add", "origin", remote, cwd=work)
    command("git", "push", "--quiet", "-u", "origin", "HEAD", cwd=work)
    return work, remote


def commit(repo):
    return command(
        "git",
        "-c",
        "user.name=Fixture",
        "-c",
        "user.email=fixture@example.test",
        "commit",
        "--quiet",
        "--allow-empty",
        "-m",
        "test: save fixture",
        cwd=repo,
    )


def settings_home(tmp_path):
    home = tmp_path / "source" / "me"
    (home / ".codex").mkdir(parents=True)
    (home / ".codex/config.toml").write_text('model = "fixture"\n')
    return home


def test_backup_round_trip_and_repeat(tmp_path, profile):
    source = settings_home(tmp_path)
    (source / ".codex/auth.json").write_text('{"token":"private"}')
    (source / ".codex/sessions").mkdir()
    (source / ".codex/sessions/session.json").write_text("private session")
    backup = tmp_path / "backup"
    manifest = restore.capture(source, backup, profile)
    assert [item["path"] for item in manifest["files"]] == [".codex/config.toml"]
    target = tmp_path / "target" / "me"
    target.mkdir(parents=True)
    restore.restore(target, backup, profile)
    restore.restore(target, backup, profile)
    assert (target / ".codex/config.toml").read_bytes() == (
        source / ".codex/config.toml"
    ).read_bytes()
    assert not (target / ".codex/auth.json").exists()
    assert not (target / ".codex/sessions").exists()


def test_backup_checks_all_conflicts_before_writing(tmp_path, profile):
    source = settings_home(tmp_path)
    (source / ".codex/AGENTS.md").write_text("Use short sentences.\n")
    backup = tmp_path / "backup"
    restore.capture(source, backup, profile)
    target = tmp_path / "target" / "me"
    (target / ".codex").mkdir(parents=True)
    (target / ".codex/config.toml").write_text('model = "local"\n')
    with pytest.raises(restore.CheckError, match="differs"):
        restore.restore(target, backup, profile)
    assert not (target / ".codex/AGENTS.md").exists()


@pytest.mark.parametrize(
    "text",
    [
        'api_key = "private-value"\n',
        '[mcp_servers.fixture.env]\nPASSWORD = "private-value"\n',
        'credential = "ghp_' + "a" * 32 + '"\n',
    ],
)
def test_capture_refuses_credential_fields(tmp_path, profile, text):
    source = settings_home(tmp_path)
    (source / ".codex/config.toml").write_text(text)
    backup = tmp_path / "backup"
    with pytest.raises(restore.CheckError, match="review"):
        restore.capture(source, backup, profile)
    assert not backup.exists()


def test_capture_accepts_environment_references(tmp_path, profile):
    source = settings_home(tmp_path)
    (source / ".codex/config.toml").write_text('api_key = "$FIXTURE_API_KEY"\n')
    restore.capture(source, tmp_path / "backup", profile)


def test_capture_refuses_link_sources(tmp_path, profile):
    source = settings_home(tmp_path)
    (source / ".codex/config.toml").unlink()
    secret = tmp_path / "private"
    secret.write_text('model = "fixture"\n')
    (source / ".codex/config.toml").symlink_to(secret)
    with pytest.raises(restore.CheckError, match="link"):
        restore.capture(source, tmp_path / "backup", profile)


def test_restore_refuses_link_parent(tmp_path, profile):
    source = settings_home(tmp_path)
    backup = tmp_path / "backup"
    restore.capture(source, backup, profile)
    target = tmp_path / "target" / "me"
    target.mkdir(parents=True)
    outside = tmp_path / "outside"
    outside.mkdir()
    (target / ".codex").symlink_to(outside, target_is_directory=True)
    with pytest.raises(restore.CheckError, match="link"):
        restore.restore(target, backup, profile)
    assert not list(outside.iterdir())


def test_backup_checksum_failure(tmp_path, profile):
    backup = tmp_path / "backup"
    restore.capture(settings_home(tmp_path), backup, profile)
    with (backup / "settings.tar.gz").open("ab") as stream:
        stream.write(b"changed")
    with pytest.raises(restore.CheckError, match="checksum"):
        restore.verify_backup(backup, profile)


@pytest.mark.parametrize(
    "name,kind",
    [
        ("../../outside", tarfile.REGTYPE),
        (".codex/config.toml", tarfile.SYMTYPE),
        (".codex/auth.json", tarfile.REGTYPE),
    ],
)
def test_archive_refuses_unsafe_members(tmp_path, profile, name, kind):
    backup = tmp_path / "backup"
    restore.capture(settings_home(tmp_path), backup, profile)
    archive = backup / "settings.tar.gz"
    with tarfile.open(archive, "w:gz") as stream:
        member = tarfile.TarInfo(name)
        member.type = kind
        member.linkname = "../../outside"
        member.size = 0
        stream.addfile(member, io.BytesIO(b""))
    manifest = json.loads((backup / "manifest.json").read_text())
    manifest["archiveSha256"] = hashlib.sha256(archive.read_bytes()).hexdigest()
    restore.write_json(backup / "manifest.json", manifest)
    with pytest.raises(restore.CheckError, match="unexpected"):
        restore.verify_backup(backup, profile)


def test_low_space_refuses_capture(tmp_path, profile, monkeypatch):
    source = settings_home(tmp_path)
    monkeypatch.setattr(restore.shutil, "disk_usage", lambda _: type("Usage", (), {"free": 0})())
    with pytest.raises(restore.CheckError, match="space"):
        restore.capture(source, tmp_path / "backup", profile)
    assert not (tmp_path / "backup").exists()


def test_memory_storage_refuses_capture(tmp_path, profile, monkeypatch):
    source = settings_home(tmp_path)
    monkeypatch.setattr(restore, "filesystem", lambda _: "tmpfs")
    with pytest.raises(restore.CheckError, match="memory"):
        restore.capture(source, tmp_path / "backup", profile)


def test_windows_links_use_distinct_gitlab_source_and_repeat(tmp_path):
    home, windows = tmp_path / "home", tmp_path / "windows"
    home.mkdir()
    (windows / ".config/git").mkdir(parents=True)
    for name in ("gh.gitconfig", "gl.gitconfig"):
        (windows / ".config/git" / name).write_text(name)
    restore.link_windows(home, windows)
    restore.link_windows(home, windows)
    assert (home / ".config/git/gl.gitconfig").read_text() == "gl.gitconfig"


def test_windows_link_conflict_prevents_partial_changes(tmp_path):
    home, windows = tmp_path / "home", tmp_path / "windows"
    (home / ".config/git").mkdir(parents=True)
    (windows / ".aws").mkdir(parents=True)
    (windows / ".azure").mkdir()
    (home / ".azure").write_text("keep")
    with pytest.raises(restore.CheckError, match="exists"):
        restore.link_windows(home, windows)
    assert not (home / ".aws").exists()


def test_clean_published_repository_passes(repository):
    work, _ = repository
    record = restore.audit_repository(work)
    assert record["blockers"] == []


def test_unpublished_commit_fails(repository):
    work, _ = repository
    commit(work)
    record = restore.audit_repository(work)
    assert "unpublished-or-unverified-objects" in record["blockers"]


def test_published_commit_without_cached_remote_ref_passes(repository):
    work, _ = repository
    commit(work)
    command("git", "push", "--quiet", "origin", "HEAD:refs/heads/another", cwd=work)
    command("git", "update-ref", "-d", "refs/remotes/origin/another", cwd=work)
    assert restore.audit_repository(work)["blockers"] == []


def test_dirty_ignored_and_stashed_data_fail(repository):
    work, _ = repository
    (work / "source.txt").write_text("changed\n")
    command("git", "stash", "push", "--quiet", cwd=work)
    (work / "untracked.txt").write_text("local\n")
    (work / ".git/info/exclude").write_text("ignored/\n")
    (work / "ignored").mkdir()
    (work / "ignored/cache").write_text("data\n")
    blockers = restore.audit_repository(work)["blockers"]
    assert {"working-files", "ignored-files", "stashes", "info-exclude"} <= set(blockers)


def test_remote_failure_and_offline_never_pass(repository):
    work, remote = repository
    shutil_target = remote.with_name("unavailable.git")
    remote.rename(shutil_target)
    assert "check-failed-or-remote-unavailable" in restore.audit_repository(work)["blockers"]
    assert "remote-not-checked" in restore.audit_repository(work, offline=True)["blockers"]


def test_reflog_only_commit_fails(repository):
    work, _ = repository
    commit(work)
    command("git", "reset", "--hard", "--quiet", "HEAD~1", cwd=work)
    blockers = restore.audit_repository(work)["blockers"]
    assert "unpublished-or-unverified-objects" in blockers


def test_unmanaged_files_block_deletion(repository):
    work, _ = repository
    (work.parent / "notes.txt").write_text("keep\n")
    report = restore.audit([work.parent])
    assert not report["safeToRemoveRepositories"]
    assert str(work.parent / "notes.txt") in report["unmanagedFiles"]
    assert report["vmDeletionApproved"] is False


def test_local_metadata_and_lfs_require_review(repository):
    work, _ = repository
    command("git", "config", "--local", "user.email", "private@example.test", cwd=work)
    (work / ".git/lfs").mkdir()
    blockers = restore.audit_repository(work)["blockers"]
    assert "local-configuration" in blockers
    assert "lfs-payload-verification-required" in blockers


def test_prepare_home_requires_explicit_replacement(tmp_path):
    home, source = tmp_path / "home", tmp_path / "managed"
    home.mkdir()
    source.mkdir()
    (home / ".gitconfig").write_text("existing")
    (source / ".gitconfig").write_text("managed")
    with pytest.raises(restore.CheckError, match="exists"):
        restore.prepare_home(home, source)
    result = restore.prepare_home(home, source, replace_existing=True)
    assert result["preservedFiles"] == 1
    assert next(home.glob(".gitconfig.wsl-rootfs-*")).read_text() == "existing"


def test_capture_removes_disabled_helper_hooks(tmp_path, profile):
    profile["captureFiles"].append(".codex/hooks.json")
    source = settings_home(tmp_path)
    hooks = {
        "hooks": {
            "PreToolUse": [
                {
                    "hooks": [
                        {"type": "command", "command": "rtk rewrite"},
                        {"type": "command", "command": "echo keep"},
                    ]
                }
            ]
        }
    }
    (source / ".codex/hooks.json").write_text(json.dumps(hooks))
    backup = tmp_path / "backup"
    manifest = restore.capture(source, backup, profile)
    _, data = restore.verify_backup(backup, profile)
    restored = json.loads(data[".codex/hooks.json"])
    assert restored["hooks"]["PreToolUse"][0]["hooks"] == [
        {"type": "command", "command": "echo keep"}
    ]
    assert manifest["omittedSettings"] == [".codex/hooks.json:disabled-helper-hooks"]


def test_capture_keeps_enabled_rtk_hooks(tmp_path, profile):
    profile["captureFiles"].append(".codex/hooks.json")
    profile["optional"]["helpers"] = True
    source = settings_home(tmp_path)
    hooks = {
        "hooks": {
            "PreToolUse": [
                {
                    "hooks": [
                        {"type": "command", "command": "rtk rewrite"},
                    ]
                }
            ]
        }
    }
    (source / ".codex/hooks.json").write_text(json.dumps(hooks))
    backup = tmp_path / "backup"
    manifest = restore.capture(source, backup, profile)
    _, data = restore.verify_backup(backup, profile)
    assert json.loads(data[".codex/hooks.json"]) == hooks
    assert manifest["omittedSettings"] == []


def test_unpublished_annotated_tag_blocks_deletion(repository):
    work, _ = repository
    command(
        "git",
        "-c",
        "user.name=Fixture",
        "-c",
        "user.email=fixture@example.test",
        "tag",
        "-a",
        "-m",
        "Local annotation",
        "local-tag",
        cwd=work,
    )
    assert "unpublished-ref-metadata" in restore.audit_repository(work)["blockers"]


def test_audit_does_not_run_clean_filters(repository):
    work, _ = repository
    (work / ".gitattributes").write_text("source.txt filter=fixture\n")
    command("git", "add", ".gitattributes", cwd=work)
    commit(work)
    effect = work / "filter-ran"
    command("git", "config", "filter.fixture.clean", f"touch '{effect}'; cat", cwd=work)
    (work / "source.txt").write_text("different\n")
    restore.audit_repository(work, offline=True)
    assert not effect.exists()


def test_prepare_home_preserves_default_skeleton_files(tmp_path):
    home, source = tmp_path / "home", tmp_path / "managed"
    home.mkdir()
    source.mkdir()
    skeleton = Path("/etc/skel/.bashrc")
    if not skeleton.is_file():
        pytest.skip("This platform has no Bash skeleton.")
    (home / ".bashrc").write_bytes(skeleton.read_bytes())
    (source / ".bashrc").write_text("managed\n")
    restore.prepare_home(home, source)
    assert next(home.glob(".bashrc.wsl-rootfs-*")).read_bytes() == skeleton.read_bytes()


def test_schema_refuses_unknown_profile_fields():
    profile = restore.load_profile()
    profile["schema_version"] = 1
    with pytest.raises(restore.CheckError, match="schema"):
        restore.validate(profile, "profile")


def test_capture_preserves_executable_user_skills(tmp_path, profile):
    profile["captureDirectories"].append(".codex/skills")
    source = settings_home(tmp_path)
    script = source / ".codex/skills/fixture/run.sh"
    script.parent.mkdir(parents=True)
    script.write_text("#!/bin/sh\necho restored\n")
    script.chmod(0o755)
    backup = tmp_path / "backup"
    restore.capture(source, backup, profile)
    target = tmp_path / "target" / "me"
    target.mkdir(parents=True)
    restore.restore(target, backup, profile)
    installed = target / ".codex/skills/fixture/run.sh"
    assert command(installed) == "restored"
    assert installed.stat().st_mode & 0o777 == 0o700


@pytest.mark.parametrize("empty_destination", [False, True])
def test_rules_clone_and_repeat_preserve_local_changes(tmp_path, repository, empty_destination):
    _, remote = repository
    home = tmp_path / "home"
    home.mkdir()
    target = home / ".codex/rules"
    if empty_destination:
        target.mkdir(parents=True)
    result = restore.install_rules(home, str(remote))
    assert result["cloned"]
    assert restore.rules_repository_matches(home, str(remote))
    (target / "source.txt").write_text("local change\n")
    (target / "local.rules").write_text("local policy\n")
    result = restore.install_rules(home, str(remote))
    assert not result["cloned"]
    assert (target / "source.txt").read_text() == "local change\n"
    assert (target / "local.rules").read_text() == "local policy\n"


def test_rules_clone_refuses_unrelated_directory(tmp_path, repository):
    _, remote = repository
    home = tmp_path / "home"
    target = home / ".codex/rules"
    target.mkdir(parents=True)
    (target / "local.rules").write_text("keep\n")
    with pytest.raises(restore.CheckError, match="another source"):
        restore.install_rules(home, str(remote))
    assert (target / "local.rules").read_text() == "keep\n"


def test_rules_clone_recovers_after_remote_failure(tmp_path, repository):
    _, remote = repository
    home = tmp_path / "home"
    home.mkdir()
    with pytest.raises(restore.CheckError, match="GitHub access"):
        restore.install_rules(home, str(remote.with_name("missing.git")))
    assert not (home / ".codex/rules").exists()
    assert not list((home / ".codex").glob(".rules-clone-*"))
    assert restore.install_rules(home, str(remote))["cloned"]


def test_rules_clone_accepts_existing_github_https_checkout(tmp_path, repository):
    _, remote = repository
    home = tmp_path / "home"
    home.mkdir()
    restore.install_rules(home, str(remote))
    target = home / ".codex/rules"
    command(
        "git", "remote", "set-url", "origin", "https://github.com/scalar0/rules.git", cwd=target
    )
    assert not restore.install_rules(home, "git@github.com:scalar0/rules.git")["cloned"]
    with pytest.raises(restore.CheckError, match="another source"):
        restore.install_rules(home, "git@github.com:scalar0/another.git")


def test_rules_clone_refuses_symlink_destination(tmp_path, repository):
    work, remote = repository
    home = tmp_path / "home"
    (home / ".codex").mkdir(parents=True)
    (home / ".codex/rules").symlink_to(work, target_is_directory=True)
    with pytest.raises(restore.CheckError, match="link"):
        restore.install_rules(home, str(remote))
