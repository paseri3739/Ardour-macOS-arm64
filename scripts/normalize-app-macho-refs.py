import os
import subprocess
from pathlib import Path


def is_macho(path: Path) -> bool:
    try:
        subprocess.run(
            ["otool", "-h", str(path)],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except subprocess.CalledProcessError:
        return False
    return True


def macho_deps(path: Path) -> list[str]:
    output = subprocess.check_output(["otool", "-L", str(path)], text=True)
    deps: list[str] = []
    for line in output.splitlines()[1:]:
        line = line.strip()
        if line:
            deps.append(line.split(" ", 1)[0])
    return deps


def macho_id(path: Path) -> str | None:
    try:
        output = subprocess.check_output(["otool", "-D", str(path)], text=True)
    except subprocess.CalledProcessError:
        return None
    lines = [line.strip() for line in output.splitlines()[1:] if line.strip()]
    return lines[0] if lines else None


def normalize_ref(ref: str) -> str:
    if not (ref.startswith("@loader_path/") or ref.startswith("@executable_path/")):
        return ref
    for segment in ("/bundled/", "/appleutility/", "/vamp/"):
        ref = ref.replace(segment, "/")
    return ref


def patch_macho(path: Path, lib_dir: Path) -> None:
    in_root_lib_dir = path.parent == lib_dir
    install_id = macho_id(path)
    if install_id:
        new_id = normalize_ref(install_id)
        if in_root_lib_dir and new_id.startswith("@loader_path/../"):
            new_id = "@loader_path/" + new_id[len("@loader_path/../") :]
        if new_id != install_id:
            subprocess.check_call(["install_name_tool", "-id", new_id, str(path)])

    for dep in macho_deps(path):
        new_dep = normalize_ref(dep)
        if in_root_lib_dir and new_dep.startswith("@loader_path/../"):
            new_dep = "@loader_path/" + new_dep[len("@loader_path/../") :]
        if new_dep != dep:
            subprocess.check_call(["install_name_tool", "-change", dep, new_dep, str(path)])


app_root = Path(os.environ["appRoot"])
lib_dir = Path(os.environ["libDir"])

for path in sorted(app_root.rglob("*")):
    if path.is_file() and is_macho(path):
        patch_macho(path, lib_dir)
