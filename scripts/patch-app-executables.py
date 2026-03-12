import os
import subprocess
from pathlib import Path


def macho_deps(path: Path) -> list[str]:
    output = subprocess.check_output(["otool", "-L", str(path)], text=True)
    deps: list[str] = []
    for line in output.splitlines()[1:]:
        line = line.strip()
        if line:
            deps.append(line.split(" ", 1)[0])
    return deps


def patch_executable(path: Path) -> None:
    for dep in macho_deps(path):
        if dep.startswith("@loader_path/../"):
            new_dep = "@executable_path/../lib/" + dep[len("@loader_path/../") :]
        elif dep.startswith("@loader_path/"):
            new_dep = "@executable_path/../lib/" + dep[len("@loader_path/") :]
        else:
            continue
        subprocess.check_call(["install_name_tool", "-change", dep, new_dep, str(path)])


lib_dir = Path(os.environ["libDir"])
macos_dir = Path(os.environ["macosDir"])
release_version = os.environ["releaseVersion"]
bundle_name = os.environ["bundleName"]

main_executable = macos_dir / bundle_name
main_executable.write_bytes((lib_dir / f"ardour-{release_version}").read_bytes())
main_executable.chmod(0o755)
patch_executable(main_executable)

for name in ("ardour9-export", "ardour9-new_session", "ardour9-new_empty_session"):
    target = lib_dir / name
    target.write_bytes((lib_dir / "utils" / name).read_bytes())
    target.chmod(0o755)
    patch_executable(target)

lua_target = lib_dir / "ardour9-lua"
lua_target.write_bytes((lib_dir / "luasession").read_bytes())
lua_target.chmod(0o755)
patch_executable(lua_target)
