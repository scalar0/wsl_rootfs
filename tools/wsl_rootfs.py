#!/usr/bin/env python3
"""Check settings backups and local Git data without exposing credential values."""

from __future__ import annotations

import argparse
import gzip
import hashlib
import io
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import tomllib
from datetime import UTC, datetime
from pathlib import Path, PurePosixPath

from jsonschema import Draft202012Validator, FormatChecker

ROOT = Path(__file__).resolve().parents[1]
MAX_FILE_BYTES = 8 * 1024 * 1024
MAX_BACKUP_BYTES = 64 * 1024 * 1024
SKIP_DIRECTORIES = {".git", ".system", "__pycache__", "node_modules", ".venv", ".cache"}
SECRET_PATTERN = re.compile(
    r"-----BEGIN (?:[A-Z ]+ )?PRIVATE KEY-----"
    r"|(?:sk-[A-Za-z0-9_-]{20,}|gh[pousr]_[A-Za-z0-9]{20,}"
    r"|github_pat_[A-Za-z0-9_]{20,}|AKIA[A-Z0-9]{16})"
)
REFERENCE_PATTERN = re.compile(r"^\$(?:[A-Z_][A-Z0-9_]*|\{[A-Z_][A-Z0-9_]*\})$")
GIT_ENV = {
    "GIT_OPTIONAL_LOCKS": "0",
    "GIT_TERMINAL_PROMPT": "0",
    "GIT_NO_LAZY_FETCH": "1",
    "LC_ALL": "C",
}


class CheckError(Exception):
    """The requested check cannot prove the required condition."""


def run(args, *, cwd=None, timeout=60, input=None, env=None):
    try:
        return subprocess.run(
            [str(arg) for arg in args],
            cwd=cwd,
            input=input,
            capture_output=True,
            env={**os.environ, **(env or {})},
            timeout=timeout,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise CheckError(f"Command failed: {Path(str(args[0])).name}") from error


def git(repo, *args, input=None, timeout=60):
    filters = []
    if args and args[0] == "status":
        keys = run(
            [
                "git",
                "-C",
                repo,
                "config",
                "--name-only",
                "--get-regexp",
                r"^filter\..*\.(clean|process|smudge|required)$",
            ],
            env=GIT_ENV,
        )
        if keys.returncode not in (0, 1):
            raise CheckError("Cannot inspect Git filter configuration.")
        names = {key.rsplit(".", 1)[0] for key in keys.stdout.decode().splitlines()}
        for name in sorted(names):
            for setting, value in (
                ("clean", "cat"),
                ("process", ""),
                ("smudge", "cat"),
                ("required", "false"),
            ):
                filters.extend(["-c", f"{name}.{setting}={value}"])
    result = run(
        [
            "git",
            "-c",
            "core.fsmonitor=false",
            "-c",
            "maintenance.auto=false",
            "-c",
            "core.hooksPath=/dev/null",
            *filters,
            "-C",
            repo,
            *args,
        ],
        input=input,
        timeout=timeout,
        env=GIT_ENV,
    )
    if result.returncode:
        raise CheckError(f"Git check failed: {args[0]}")
    return result.stdout


def validate(document, schema):
    contract = json.loads((ROOT / "schemas" / f"{schema}.schema.json").read_text())
    validator = Draft202012Validator(contract, format_checker=FormatChecker())
    if next(validator.iter_errors(document), None):
        raise CheckError(f"The {schema} document does not match its schema.")


def load_profile():
    profile = json.loads((ROOT / "nix/profile.json").read_text())
    validate(profile, "profile")
    if profile["homeDirectory"] != "/home/" + profile["username"]:
        raise CheckError("The home directory does not match the Linux user.")
    return profile


def write_json(path, document):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    try:
        with temporary.open("x", encoding="ascii") as stream:
            os.chmod(temporary, 0o600)
            json.dump(document, stream, indent=2, ensure_ascii=True)
            stream.write("\n")
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def relative_path(value):
    path = PurePosixPath(value)
    if (
        not value
        or any(ord(c) < 32 for c in value)
        or path.is_absolute()
        or ".." in path.parts
        or str(path) != value
    ):
        raise CheckError("A settings path is not a safe relative path.")
    return path


def regular_file(path):
    if not stat.S_ISREG(path.lstat().st_mode):
        raise CheckError("A settings source is not a regular file.")
    if path.stat().st_size > MAX_FILE_BYTES:
        raise CheckError("A settings file exceeds the size limit.")


def check_secret_data(data, path, profile):
    text = data.decode("utf-8")
    if SECRET_PATTERN.search(text):
        raise CheckError(f"Credential content needs review: {path}")
    structured = None
    try:
        if path.endswith(".toml"):
            structured = tomllib.loads(text)
        elif path.endswith(".json"):
            structured = json.loads(text)
    except (ValueError, tomllib.TOMLDecodeError) as error:
        raise CheckError(f"Settings syntax needs review: {path}") from error

    def walk(value):
        if isinstance(value, dict):
            for key, item in value.items():
                normalized = key.lower().replace("-", "_")
                sensitive = any(
                    normalized == name or normalized.endswith("_" + name)
                    for name in profile["secretKeys"]
                )
                if (
                    sensitive
                    and item
                    and not (isinstance(item, str) and REFERENCE_PATTERN.fullmatch(item))
                ):
                    raise CheckError(f"Credential field needs review: {path}")
                if normalized == "env" and isinstance(item, dict):
                    if any(not REFERENCE_PATTERN.fullmatch(str(v)) for v in item.values()):
                        raise CheckError(f"Environment values need review: {path}")
                walk(item)
        elif isinstance(value, list):
            for item in value:
                walk(item)

    walk(structured)


def approved_path(path, profile):
    relative_path(path)
    return path in profile["captureFiles"] or any(
        path.startswith(directory + "/")
        and not any(part in SKIP_DIRECTORIES for part in PurePosixPath(path).parts)
        for directory in profile["captureDirectories"]
    )


def settings_sources(home, profile):
    candidates = set(profile["captureFiles"])
    for directory in profile["captureDirectories"]:
        source = home / directory
        if source.is_symlink():
            raise CheckError(f"A settings directory is a link: {directory}")
        if not source.exists():
            continue
        for parent, directories, files in os.walk(source, followlinks=False):
            directories[:] = sorted(d for d in directories if d not in SKIP_DIRECTORIES)
            for name in directories:
                if (Path(parent) / name).is_symlink():
                    raise CheckError("A settings directory contains a link.")
            for name in files:
                candidates.add((Path(parent) / name).relative_to(home).as_posix())
    for name in sorted(candidates):
        relative_path(name)
        path = home / name
        if path.is_symlink():
            raise CheckError(f"A settings file is a link: {name}")
        if not path.exists():
            continue
        if not path.resolve().is_relative_to(home.resolve()):
            raise CheckError("A settings source escapes the home directory.")
        regular_file(path)
        parent = path.parent
        while parent != home:
            if parent.is_symlink():
                raise CheckError(f"A settings parent is a link: {name}")
            parent = parent.parent
        yield name, path


def windows_profile(override=None):
    if override:
        path = Path(override).resolve()
    else:
        result = run(
            [
                "powershell.exe",
                "-NoProfile",
                "-NonInteractive",
                "-Command",
                "[Environment]::GetFolderPath('UserProfile')",
            ],
            timeout=20,
        )
        if result.returncode:
            raise CheckError("Cannot detect the Windows profile. Supply --windows-profile.")
        converted = run(["wslpath", "-u", result.stdout.decode().strip()])
        if converted.returncode:
            raise CheckError("Cannot convert the Windows profile path.")
        path = Path(converted.stdout.decode().strip()).resolve()
    if not path.is_dir():
        raise CheckError("The Windows profile directory is unavailable.")
    return path


def filesystem(path):
    result = run(["findmnt", "-n", "-o", "FSTYPE", "-T", path])
    if result.returncode:
        raise CheckError("Cannot check the backing file system.")
    return result.stdout.decode().strip()


def check_space(path, required, reserve, *, allow_memory=False):
    path = Path(path)
    while not path.exists():
        path = path.parent
    kind = filesystem(path)
    if not allow_memory and kind in {"tmpfs", "ramfs"}:
        raise CheckError("The target uses memory-backed storage.")
    free = shutil.disk_usage(path).free
    if free < required + reserve:
        raise CheckError("Free space is insufficient. Free disk space before retrying.")
    return {"freeBytes": free, "requiredBytes": required, "reserveBytes": reserve}


def capture_data(name, source, profile):
    data = source.read_bytes()
    if name == ".codex/hooks.json":
        disabled = ["headroom", "tokensave"]
        if not profile["optional"]["helpers"]:
            disabled.append("rtk")
        pattern = r"(^|[^A-Za-z0-9_-])(" + "|".join(disabled) + r")([^A-Za-z0-9_-]|$)"
        result = run(
            ["jq", "--arg", "disabled", pattern, "-f", ROOT / "filters/capture-hooks.jq"],
            input=data,
        )
        if result.returncode:
            raise CheckError("Cannot filter the agent hooks.")
        return result.stdout, json.loads(result.stdout) != json.loads(data)
    return data, False


def capture(home, destination, profile):
    sources = list(settings_sources(home, profile))
    size = sum(path.stat().st_size for _, path in sources)
    if size > MAX_BACKUP_BYTES:
        raise CheckError("The settings backup exceeds the size limit.")
    check_space(destination.parent, size * 2, profile["reserveBytes"])
    if destination.exists():
        raise CheckError("The backup destination already exists.")
    destination.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=".capture-", dir=destination.parent))
    entries = []
    omitted = []
    try:
        with tarfile.open(staging / "settings.tar.gz", "w:gz") as archive:
            for name, source in sources:
                data, filtered = capture_data(name, source, profile)
                if filtered:
                    omitted.append(f"{name}:disabled-helper-hooks")
                check_secret_data(data, name, profile)
                item = tarfile.TarInfo(name)
                item.size = len(data)
                item.mode = 0o700 if source.stat().st_mode & stat.S_IXUSR else 0o600
                item.mtime = 0
                archive.addfile(item, io.BytesIO(data))
                entries.append(
                    {
                        "path": name,
                        "size": len(data),
                        "sha256": hashlib.sha256(data).hexdigest(),
                        "mode": item.mode,
                    }
                )
        manifest = {
            "createdAt": datetime.now(UTC).isoformat(),
            "username": home.name,
            "files": entries,
            "archiveSha256": hashlib.sha256((staging / "settings.tar.gz").read_bytes()).hexdigest(),
            "excluded": ["repositories", "credentials", "agent-sessions", "caches", "toolchains"],
            "omittedSettings": omitted,
        }
        validate(manifest, "backup")
        write_json(staging / "manifest.json", manifest)
        verify_backup(staging, profile)
        staging.rename(destination)
    finally:
        if staging.exists():
            shutil.rmtree(staging)
    return manifest


def verify_backup(source, profile):
    if source.is_symlink() or not source.is_dir():
        raise CheckError("The backup directory is unavailable or is a link.")
    for name in ("manifest.json", "settings.tar.gz"):
        path = source / name
        if path.is_symlink():
            raise CheckError("A backup member is a link.")
        regular_file(path) if name == "manifest.json" else None
    manifest = json.loads((source / "manifest.json").read_text())
    validate(manifest, "backup")
    archive_path = source / "settings.tar.gz"
    if not stat.S_ISREG(archive_path.lstat().st_mode):
        raise CheckError("The settings archive is not a regular file.")
    if archive_path.stat().st_size > MAX_BACKUP_BYTES:
        raise CheckError("The settings archive exceeds the size limit.")
    if hashlib.sha256(archive_path.read_bytes()).hexdigest() != manifest["archiveSha256"]:
        raise CheckError("The settings archive checksum does not match.")
    expected = {}
    for item in manifest["files"]:
        if not approved_path(item["path"], profile) or item["path"] in expected:
            raise CheckError("The backup contains an unexpected or duplicate path.")
        expected[item["path"]] = item
    content = {}
    total = 0
    with gzip.open(archive_path, "rb") as stream:
        unpacked = stream.read(MAX_BACKUP_BYTES + 16 * 1024 * 1024 + 1)
    if len(unpacked) > MAX_BACKUP_BYTES + 16 * 1024 * 1024:
        raise CheckError("The unpacked archive exceeds the size limit.")
    with tarfile.open(fileobj=io.BytesIO(unpacked), mode="r:") as archive:
        for member in archive:
            name = member.name
            if not member.isfile() or name not in expected or name in content:
                raise CheckError("The archive contains an unexpected member.")
            item = expected[name]
            if member.mode != item.get("mode", 0o600):
                raise CheckError("An archive member has invalid permissions.")
            if member.size != item["size"] or member.size > MAX_FILE_BYTES:
                raise CheckError("An archive member has an invalid size.")
            total += member.size
            if total > MAX_BACKUP_BYTES:
                raise CheckError("The unpacked backup exceeds the size limit.")
            data = archive.extractfile(member).read(MAX_FILE_BYTES + 1)
            if hashlib.sha256(data).hexdigest() != item["sha256"]:
                raise CheckError("A settings file checksum does not match.")
            check_secret_data(data, name, profile)
            content[name] = data
    if set(content) != set(expected):
        raise CheckError("The backup is incomplete.")
    return manifest, content


def safe_target(home, name):
    relative_path(name)
    target = home / name
    parent = target.parent
    while parent != home:
        if parent.is_symlink():
            raise CheckError(f"A destination parent is a link: {name}")
        parent = parent.parent
    if target.is_symlink():
        raise CheckError(f"A destination is a link: {name}")
    return target


def restore(home, source, profile):
    manifest, content = verify_backup(source, profile)
    if manifest["username"] != profile["username"]:
        raise CheckError("The backup user does not match the selected profile.")
    modes = {item["path"]: item.get("mode", 0o600) for item in manifest["files"]}
    targets = [(safe_target(home, name), data) for name, data in content.items()]
    for target, data in targets:
        if target.exists() and (not target.is_file() or target.read_bytes() != data):
            raise CheckError(f"An existing settings file differs: {target.relative_to(home)}")
    for target, data in targets:
        if target.exists():
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        descriptor, temporary = tempfile.mkstemp(prefix=".wsl-rootfs-", dir=target.parent)
        try:
            os.fchmod(descriptor, modes[target.relative_to(home).as_posix()])
            with os.fdopen(descriptor, "wb") as stream:
                stream.write(data)
                stream.flush()
                os.fsync(stream.fileno())
            os.link(temporary, target)
        finally:
            Path(temporary).unlink(missing_ok=True)
    return {"restoredFiles": len(targets)}


def link_windows(home, windows):
    mappings = {
        ".aws": ".aws",
        ".azure": ".azure",
        ".config/git/windows.gitconfig": ".gitconfig",
        ".config/git/.gitcommit": ".config/git/.gitcommit",
        ".config/git/gh.gitconfig": ".config/git/gh.gitconfig",
        ".config/git/gl.gitconfig": ".config/git/gl.gitconfig",
    }
    pending = []
    links = []
    for local, remote in mappings.items():
        target = windows / remote
        link = home / local
        if not target.exists():
            pending.append(local)
            continue
        if link.is_symlink() and link.resolve() == target.resolve():
            continue
        if link.exists() or link.is_symlink():
            raise CheckError(f"A Windows link destination already exists: {local}")
        parent = link.parent
        while parent != home:
            if parent.is_symlink():
                raise CheckError("A Windows link parent is a link.")
            parent = parent.parent
        links.append((link, target))
    for link, target in links:
        link.parent.mkdir(parents=True, exist_ok=True)
        link.symlink_to(target, target_is_directory=target.is_dir())
    return {"linkedFiles": len(links), "unavailable": pending}


def repository_identity(repository):
    for prefix in ("git@github.com:", "https://github.com/"):
        if repository.startswith(prefix):
            return repository[len(prefix) :].rstrip("/").removesuffix(".git").casefold()
    return repository


def rules_repository_matches(home, repository):
    target = home / ".codex/rules"
    if target.is_symlink() or (home / ".codex").is_symlink() or not target.is_dir():
        return False
    try:
        top = Path(os.fsdecode(git(target, "rev-parse", "--show-toplevel").strip()))
        origin = os.fsdecode(git(target, "config", "--get", "remote.origin.url").strip())
    except CheckError:
        return False
    return top.resolve() == target.resolve() and (
        repository_identity(origin) == repository_identity(repository)
    )


def install_rules(home, repository):
    parent = home / ".codex"
    target = parent / "rules"
    if parent.is_symlink() or target.is_symlink():
        raise CheckError("The rules destination is a link. Review it before retrying.")
    if target.exists():
        if not target.is_dir():
            raise CheckError("The rules destination is not a directory.")
        if any(target.iterdir()):
            if not rules_repository_matches(home, repository):
                raise CheckError(
                    "The rules directory has another source. Review it before retrying."
                )
            return {"path": str(target), "cloned": False}
    parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".rules-clone-", dir=parent) as temporary:
        staging = Path(temporary) / "rules"
        try:
            git(temporary, "clone", "--quiet", "--", repository, staging, timeout=120)
        except CheckError as error:
            raise CheckError(
                "Cannot clone the Codex rules. Restore GitHub access before retrying."
            ) from error
        staging.rename(target)
    return {"path": str(target), "cloned": True}


def prepare_home(home, source, *, replace_existing=False):
    pending = []
    stamp = datetime.now(UTC).strftime("%Y%m%dT%H%M%S%fZ")
    for parent, _, files in os.walk(source, followlinks=True):
        for name in files:
            source_file = Path(parent) / name
            relative = source_file.relative_to(source)
            target = home / relative
            if not target.exists() and not target.is_symlink():
                continue
            if target.is_symlink() and str(target.resolve()).startswith("/nix/store/"):
                continue
            skeleton = Path("/etc/skel") / relative
            default_file = (
                target.is_file()
                and not target.is_symlink()
                and skeleton.is_file()
                and target.read_bytes() == skeleton.read_bytes()
            )
            if not replace_existing and not default_file:
                raise CheckError(f"A managed settings file already exists: {relative}")
            parent_target = target.parent
            while parent_target != home:
                if parent_target.is_symlink():
                    raise CheckError("A managed settings parent is a link.")
                parent_target = parent_target.parent
            backup = target.with_name(f"{target.name}.wsl-rootfs-{stamp}")
            if backup.exists() or backup.is_symlink():
                raise CheckError("A settings backup path already exists.")
            pending.append((target, backup))
    moved = []
    try:
        for target, backup in pending:
            target.rename(backup)
            moved.append((target, backup))
    except OSError:
        for target, backup in reversed(moved):
            backup.rename(target)
        raise
    return {"preservedFiles": len(moved)}


def walk_error(error):
    raise CheckError("A directory scan failed. Check directory access.") from error


def discover_repositories(roots):
    repositories = set()
    unmanaged = []
    for root in roots:
        if not root.exists():
            continue
        for parent, directories, files in os.walk(root, followlinks=False, onerror=walk_error):
            path = Path(parent)
            marker = ".git" in directories or ".git" in files
            bare = "HEAD" in files and "objects" in directories and "refs" in directories
            if marker or bare:
                repositories.add(path)
            if not any(path == repo or path.is_relative_to(repo) for repo in repositories):
                unmanaged.extend(str(path / name) for name in files if name != ".git")
                unmanaged.extend(
                    str(path / name) for name in directories if (path / name).is_symlink()
                )
            directories[:] = sorted(
                name
                for name in directories
                if name not in SKIP_DIRECTORIES
                and not name.startswith("bazel-")
                and not (path / name).is_symlink()
                and not bare
            )
    return sorted(repositories), sorted(set(unmanaged))


def split_paths(data):
    return [os.fsdecode(value) for value in data.split(b"\0") if value]


def local_metadata(repo, gitdir):
    blockers = []
    config = git(repo, "config", "--local", "--name-only", "--list").decode().splitlines()
    ordinary = re.compile(
        r"^(core\.(repositoryformatversion|filemode|bare|logallrefupdates)"
        r"|remote\..+\.(url|fetch)|branch\..+\.(remote|merge)"
        r"|submodule\..+\.(url|active))$"
    )
    if any(not ordinary.fullmatch(key) for key in config):
        blockers.append("local-configuration")
    hooks = gitdir / "hooks"
    if hooks.exists() and any(
        p.is_file() and not p.name.endswith(".sample") for p in hooks.iterdir()
    ):
        blockers.append("local-hooks")
    for name in ("info/exclude", "info/attributes"):
        file = gitdir / name
        if file.exists() and any(
            line.strip() and not line.lstrip().startswith("#")
            for line in file.read_text(errors="replace").splitlines()
        ):
            blockers.append(name.replace("/", "-"))
    if (gitdir / "rr-cache").exists() and any((gitdir / "rr-cache").iterdir()):
        blockers.append("rerere-data")
    if (gitdir / "lfs").exists():
        blockers.append("lfs-payload-verification-required")
    return blockers


def audit_repository(repo, *, offline=False):
    record = {"path": str(repo), "blockers": [], "details": {}}
    blockers = record["blockers"]
    details = record["details"]
    try:
        bare = git(repo, "rev-parse", "--is-bare-repository").strip() == b"true"
        if not bare:
            top = Path(os.fsdecode(git(repo, "rev-parse", "--show-toplevel").strip()))
            if top.resolve() != repo.resolve():
                blockers.append("invalid-repository-marker")
                return record
            submodules = git(repo, "ls-files", "--stage", "-z")
            for entry in submodules.split(b"\0"):
                if entry.startswith(b"160000 "):
                    name = os.fsdecode(entry.split(b"\t", 1)[1])
                    if not (repo / name / ".git").exists():
                        blockers.append("uninitialized-submodule")
        gitdir = Path(os.fsdecode(git(repo, "rev-parse", "--absolute-git-dir").strip()))
        if not bare:
            status = git(repo, "status", "--porcelain=v1", "-z", "--untracked-files=all")
            if status:
                blockers.append("working-files")
                details["workingFiles"] = split_paths(status)
            ignored = split_paths(
                git(
                    repo,
                    "ls-files",
                    "--others",
                    "--ignored",
                    "--exclude-standard",
                    "--directory",
                    "-z",
                )
            )
            if ignored:
                blockers.append("ignored-files")
                details["ignoredFiles"] = ignored
        stashes = git(repo, "stash", "list", "--format=%H").decode().splitlines()
        if stashes:
            blockers.append("stashes")
            details["stashes"] = stashes
        worktrees = git(repo, "worktree", "list", "--porcelain").decode()
        if worktrees.count("worktree ") > 1:
            blockers.append("linked-worktrees")
        blockers.extend(local_metadata(repo, gitdir))
        refs = git(repo, "for-each-ref", "--format=%(objectname) %(refname)").decode().splitlines()
        details["localRefs"] = [
            {"oid": line.split(" ", 1)[0], "name": line.split(" ", 1)[1]}
            for line in refs
            if not line.split(" ", 1)[1].startswith("refs/remotes/")
        ]
        remotes = git(repo, "remote").decode().splitlines()
        if offline:
            blockers.append("remote-not-checked")
            return record
        if not remotes:
            blockers.append("no-remotes")
            return record
        remote_oids = set()
        temporary_root = Path(
            os.environ.get("TMPDIR", str(Path.home() / ".local/state/wsl-rootfs/tmp"))
        )
        temporary_root.mkdir(parents=True, exist_ok=True)
        check_space(temporary_root, 0, 0)
        with tempfile.TemporaryDirectory(
            prefix="wsl-rootfs-audit-", dir=temporary_root
        ) as directory:
            mirror = Path(directory)
            object_format = git(repo, "rev-parse", "--show-object-format").decode().strip()
            git(mirror, "init", "--bare", "--quiet", f"--object-format={object_format}")
            for index, remote in enumerate(remotes):
                advertised = git(repo, "ls-remote", "--refs", remote, timeout=120)
                advertised_oids = {line.split()[0].decode() for line in advertised.splitlines()}
                if not advertised_oids:
                    blockers.append("empty-remote")
                    continue
                url = git(repo, "remote", "get-url", remote).decode().strip()
                git(
                    mirror,
                    "-c",
                    "protocol.file.allow=always",
                    "fetch",
                    "--quiet",
                    "--filter=blob:none",
                    "--no-tags",
                    "--no-write-fetch-head",
                    url,
                    f"+refs/heads/*:refs/audit/{index}/heads/*",
                    f"+refs/tags/*:refs/audit/{index}/tags/*",
                    timeout=180,
                )
                fetched = set(
                    git(
                        mirror,
                        "for-each-ref",
                        "--format=%(objectname)",
                        f"refs/audit/{index}/",
                    )
                    .decode()
                    .splitlines()
                )
                if not fetched.issubset(advertised_oids):
                    blockers.append("remote-changed-during-check")
                remote_oids.update(fetched)
            details["checkedRemoteCount"] = len(remotes)
            commits = set(git(repo, "reflog", "--all", "--format=%H").decode().splitlines())
            head = run(["git", "-C", repo, "rev-parse", "--verify", "HEAD"], env=GIT_ENV)
            if head.returncode == 0:
                commits.add(head.stdout.decode().strip())
            for item in details["localRefs"]:
                oid = item["oid"]
                kind = git(repo, "cat-file", "-t", oid).strip()
                if kind != b"commit" and oid not in remote_oids:
                    blockers.append("unpublished-ref-metadata")
                if oid not in remote_oids:
                    contains = run(
                        [
                            "git",
                            "-C",
                            mirror,
                            "for-each-ref",
                            f"--contains={oid}",
                            "--format=%(refname)",
                        ],
                        env=GIT_ENV,
                    )
                    if contains.returncode or not contains.stdout.strip():
                        commits.add(oid)
            unpublished = []
            for oid in sorted(commits):
                if oid in remote_oids:
                    continue
                contains = run(
                    [
                        "git",
                        "-C",
                        mirror,
                        "for-each-ref",
                        f"--contains={oid}",
                        "--format=%(refname)",
                    ],
                    env=GIT_ENV,
                )
                if contains.returncode or not contains.stdout.strip():
                    unpublished.append(oid)
            if unpublished:
                blockers.append("unpublished-or-unverified-objects")
                details["unverifiedObjects"] = unpublished
            fsck = run(
                ["git", "-C", repo, "fsck", "--no-reflogs", "--unreachable", "--no-progress"],
                env=GIT_ENV,
                timeout=120,
            )
            if fsck.returncode:
                blockers.append("object-check-failed")
            unreachable = [
                line.split()[-1].decode()
                for line in fsck.stdout.splitlines()
                if line.startswith((b"unreachable commit ", b"unreachable blob "))
            ]
            if unreachable:
                blockers.append("unreachable-objects")
                details["unreachableObjects"] = unreachable
    except CheckError:
        blockers.append("check-failed-or-remote-unavailable")
    record["blockers"] = sorted(set(blockers))
    return record


def audit(roots, *, offline=False):
    repositories, unmanaged = discover_repositories(roots)
    records = [audit_repository(repo, offline=offline) for repo in repositories]
    result = {
        "createdAt": datetime.now(UTC).isoformat(),
        "scope": "repositories",
        "offline": offline,
        "repositories": records,
        "unmanagedFiles": unmanaged,
        "safeToRemoveRepositories": bool(records)
        and not unmanaged
        and all(not item["blockers"] for item in records),
        "vmDeletionApproved": False,
    }
    validate(result, "audit")
    return result


def scan_public(profile):
    count = 0
    for directory in (ROOT / "nix", ROOT / "backups/original-shell"):
        for path in directory.rglob("*"):
            if path.is_symlink():
                raise CheckError("A public source contains a link.")
            if not path.is_file():
                continue
            regular_file(path)
            check_secret_data(path.read_bytes(), path.relative_to(ROOT).as_posix(), profile)
            count += 1
    return {"checkedPublicFiles": count}


def inventory(home):
    commands = [
        "git",
        "gh",
        "op",
        "rustup",
        "rustc",
        "uv",
        "node",
        "npm",
        "bazel",
        "aspect",
        "depot",
        "codex",
        "clang",
        "tmux",
        "just",
    ]
    return {
        "createdAt": datetime.now(UTC).isoformat(),
        "home": str(home),
        "commands": {name: shutil.which(name) for name in commands},
        "windowsLinks": {
            name: os.readlink(home / name)
            for name in (".gitconfig", ".aws", ".azure")
            if (home / name).is_symlink()
        },
    }


def verification_report(checks, versions):
    actions = json.loads((ROOT / "nix/recovery.json").read_text())
    validate(actions, "recovery")
    next_actions = []
    for check in checks:
        if check["ok"]:
            continue
        message = next(
            (
                value
                for prefix, value in actions.items()
                if prefix != "default" and check["name"].startswith(prefix)
            ),
            actions["default"],
        )
        next_actions.append({"check": check["name"], "action": message})
    return {
        "checks": checks,
        "versions": versions,
        "ok": all(item["ok"] for item in checks),
        "nextActions": next_actions,
    }


def reconnect(home, *, interactive=False, plugins=False):
    checks = []
    for name, status, login in (
        ("github-access", ["gh", "auth", "status"], ["gh", "auth", "login"]),
        ("codex-access", ["codex", "login", "status"], ["codex", "login", "--device-auth"]),
    ):
        try:
            authenticated = run(status, timeout=30).returncode == 0
            if not authenticated and interactive and sys.stdin.isatty():
                subprocess.run(login, check=False)
                authenticated = run(status, timeout=30).returncode == 0
        except CheckError:
            authenticated = False
        checks.append({"name": name, "ok": authenticated})
    config_file = home / ".codex/config.toml"
    authenticated = any(item["name"] == "codex-access" and item["ok"] for item in checks)
    if plugins and config_file.exists() and not authenticated:
        checks.append({"name": "plugin-login-required", "ok": False})
    if plugins and config_file.exists() and authenticated:
        config = tomllib.loads(config_file.read_text())
        selections = [
            key
            for key, value in config.get("plugins", {}).items()
            if isinstance(value, dict) and value.get("enabled", False)
        ]
        if config.get("marketplaces"):
            try:
                ok = run(["codex", "plugin", "marketplace", "upgrade"], timeout=180).returncode == 0
            except CheckError:
                ok = False
            checks.append({"name": "plugin-marketplaces", "ok": ok})
        for selector in selections:
            try:
                ok = (
                    run(
                        ["codex", "plugin", "add", "--json", "--", selector], timeout=180
                    ).returncode
                    == 0
                )
            except CheckError:
                ok = False
            checks.append({"name": f"plugin:{selector}", "ok": ok})
    result = verification_report(checks, {})
    validate(result, "verification")
    return result


def verify(home, *, sign=False):
    checks = []
    catalog_file = home / ".config/wsl-rootfs/catalog.json"
    if catalog_file.exists():
        catalog = json.loads(catalog_file.read_text())
        validate(catalog, "catalog")
        for package in catalog:
            for command in package["commands"]:
                found = shutil.which(command)
                expected = Path(package["storePath"]) / "bin" / command
                good = bool(found) and Path(found).resolve() == expected.resolve()
                checks.append({"name": command, "ok": good})
    else:
        checks.append({"name": "catalog", "ok": False})
    temporary = home / ".local/state/wsl-rootfs/tmp"
    checks.append(
        {
            "name": "disk-temporary-storage",
            "ok": temporary.is_dir() and filesystem(temporary) not in {"tmpfs", "ramfs"},
        }
    )
    for command in ("rustc", "cargo", "uv", "node", "bazel", "ssh.exe", "op-ssh-sign-wsl.exe"):
        checks.append({"name": f"available:{command}", "ok": bool(shutil.which(command))})
    for name in (
        ".config/git/windows.gitconfig",
        ".config/git/.gitcommit",
        ".config/git/gh.gitconfig",
        ".config/git/gl.gitconfig",
        ".aws",
        ".azure",
    ):
        checks.append({"name": name, "ok": (home / name).exists()})
    versions = {}
    for command, args in {
        "rustup": ["--version"],
        "rustc": ["--version"],
        "uv": ["--version"],
        "node": ["--version"],
        "git": ["--version"],
    }.items():
        if shutil.which(command):
            result = run([command, *args], timeout=20)
            if result.returncode == 0:
                versions[command] = result.stdout.decode(errors="replace").strip()
            checks.append({"name": f"usable:{command}", "ok": result.returncode == 0})
    for name, command in {
        "github-access": ["gh", "auth", "status"],
        "codex-access": ["codex", "login", "status"],
        "1password-access": ["op.exe" if shutil.which("op.exe") else "op", "whoami"],
    }.items():
        try:
            checks.append({"name": name, "ok": run(command, timeout=20).returncode == 0})
        except CheckError:
            checks.append({"name": name, "ok": False})
    profile = load_profile()
    checks.append(
        {
            "name": "codex-rules",
            "ok": rules_repository_matches(home, profile["codexRulesRepository"]),
        }
    )
    for package in profile["basePackages"]:
        status = run(["dpkg-query", "-W", "-f=" + chr(36) + "{Status}", package])
        checks.append({"name": f"ubuntu:{package}", "ok": status.stdout == b"install ok installed"})
        version = run(["dpkg-query", "-W", "-f=" + chr(36) + "{Version}", package])
        if version.returncode == 0:
            versions[f"ubuntu:{package}"] = version.stdout.decode()
    python = run(
        [
            "uv",
            "python",
            "find",
            "--managed-python",
            "--no-python-downloads",
            profile["pythonVersion"],
        ]
    )
    checks.append({"name": "managed-python", "ok": python.returncode == 0})
    if profile["optional"]["lighttpd"]:
        checks.append(
            {
                "name": "lighttpd-service",
                "ok": run(["systemctl", "is-active", "--quiet", "lighttpd.service"]).returncode
                == 0,
            }
        )
    if sign:
        root = home / ".local/state/wsl-rootfs/tmp"
        root.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=root, prefix="signing-") as directory:
            try:
                git(directory, "init", "--quiet")
                git(directory, "remote", "add", "origin", profile["gitTestRemote"])
                git(
                    directory,
                    "commit",
                    "--quiet",
                    "--allow-empty",
                    "-S",
                    "-m",
                    "test: verify signing",
                    timeout=120,
                )
                signed = b"\ngpgsig " in git(directory, "cat-file", "commit", "HEAD")
                checks.append({"name": "git-signing", "ok": signed})
            except CheckError:
                checks.append({"name": "git-signing", "ok": False})
    result = verification_report(checks, versions)
    validate(result, "verification")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--home", type=Path, default=Path.home())
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("inventory")
    subparsers.add_parser("scan-public")
    subparsers.add_parser("rules")
    subparsers.add_parser("validate")
    backup_parser = subparsers.add_parser("capture")
    backup_parser.add_argument("--destination", type=Path)
    backup_parser.add_argument("--windows-profile")
    restore_parser = subparsers.add_parser("restore")
    restore_parser.add_argument("source", type=Path)
    check_parser = subparsers.add_parser("check-backup")
    check_parser.add_argument("source", type=Path)
    links_parser = subparsers.add_parser("links")
    links_parser.add_argument("--windows-profile")
    audit_parser = subparsers.add_parser("audit")
    audit_parser.add_argument("--root", type=Path, action="append")
    audit_parser.add_argument("--offline", action="store_true")
    audit_parser.add_argument("--output", type=Path)
    prepare_parser = subparsers.add_parser("prepare-home")
    prepare_parser.add_argument("source", type=Path)
    prepare_parser.add_argument("--replace-existing", action="store_true")
    access_parser = subparsers.add_parser("access")
    access_parser.add_argument("--interactive", action="store_true")
    access_parser.add_argument("--plugins", action="store_true")
    verify_parser = subparsers.add_parser("verify")
    verify_parser.add_argument("--sign", action="store_true")
    args = parser.parse_args()
    try:
        profile = load_profile()
        home = args.home.absolute()
        result = {}
        exit_code = 0
        if args.command == "inventory":
            result = inventory(home)
            validate(result, "inventory")
        elif args.command == "scan-public":
            result = scan_public(profile)
        elif args.command == "validate":
            validate(json.loads((ROOT / "nix/installer.json").read_text()), "installer")
            validate(json.loads((ROOT / "nix/artifacts.json").read_text()), "artifacts")
            result = {"valid": True}
        elif args.command == "capture":
            destination = args.destination
            if destination is None:
                windows = windows_profile(args.windows_profile)
                destination = (
                    windows
                    / profile["backupDirectory"]
                    / datetime.now(UTC).strftime("%Y%m%dT%H%M%S%fZ")
                )
            result = capture(home, destination.absolute(), profile)
            result = {
                "destination": str(destination),
                "files": len(result["files"]),
                "omittedSettings": result["omittedSettings"],
            }
        elif args.command == "check-backup":
            manifest, _ = verify_backup(args.source, profile)
            result = {"valid": True, "files": len(manifest["files"])}
        elif args.command == "restore":
            result = restore(home, args.source, profile)
        elif args.command == "rules":
            result = install_rules(home, profile["codexRulesRepository"])
        elif args.command == "links":
            result = link_windows(home, windows_profile(args.windows_profile))
        elif args.command == "audit":
            roots = args.root or [
                home / "src",
                home / ".codex/rules",
                home / ".config/git/hooks",
            ]
            result = audit(roots, offline=args.offline)
            if args.output:
                write_json(args.output, result)
            exit_code = 0 if result["safeToRemoveRepositories"] else 2
        elif args.command == "prepare-home":
            result = prepare_home(home, args.source, replace_existing=args.replace_existing)
        elif args.command == "access":
            result = reconnect(home, interactive=args.interactive, plugins=args.plugins)
            write_json(home / ".local/state/wsl-rootfs/access.json", result)
            exit_code = 0 if result["ok"] else 2
        elif args.command == "verify":
            result = verify(home, sign=args.sign)
            write_json(home / ".local/state/wsl-rootfs/verification.json", result)
            exit_code = 0 if result["ok"] else 2
        print(json.dumps(result, indent=2, ensure_ascii=True))
        return exit_code
    except (CheckError, ValueError, OSError, UnicodeError, tarfile.TarError, EOFError) as error:
        message = (
            str(error) if isinstance(error, CheckError) else "Check failed. Review the input paths."
        )
        print(f"wsl-rootfs: {message}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
