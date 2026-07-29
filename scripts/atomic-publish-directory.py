#!/usr/bin/env python3
import ctypes
import errno
import os
import sys
from pathlib import Path


AT_FDCWD = -2
RENAME_EXCL = 0x00000004


def contains_symlink(path: Path) -> bool:
    return any(component.is_symlink() for component in (path, *path.parents))


def main() -> int:
    arguments = sys.argv[1:]
    forced_errno = None
    if len(arguments) == 4 and arguments[:1] == ["--force-errno"]:
        try:
            forced_errno = int(arguments[1])
        except ValueError:
            return 64
        arguments = arguments[2:]
    if len(arguments) != 2:
        print(
            "Usage: atomic-publish-directory.py "
            "<source-directory> <destination-directory>",
            file=sys.stderr,
        )
        return 64

    source = Path(arguments[0])
    destination = Path(arguments[1])
    if not source.is_absolute() or not destination.is_absolute():
        print("Publication paths must be absolute.", file=sys.stderr)
        return 64
    if source.is_symlink() or not source.is_dir():
        print("Source is not a regular directory.", file=sys.stderr)
        return 66
    if contains_symlink(source) or contains_symlink(destination):
        print("Publication paths cannot contain symbolic links.", file=sys.stderr)
        return 73

    if forced_errno is not None:
        status = forced_errno
    else:
        try:
            libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
            rename_exclusive = libc.renameatx_np
        except (AttributeError, OSError):
            print("Atomic publication is unsupported on this host.", file=sys.stderr)
            return 78
        rename_exclusive.argtypes = [
            ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p,
            ctypes.c_uint,
        ]
        rename_exclusive.restype = ctypes.c_int
        result = rename_exclusive(
            AT_FDCWD, os.fsencode(source), AT_FDCWD, os.fsencode(destination),
            RENAME_EXCL,
        )
        if result == 0:
            return 0
        status = ctypes.get_errno()

    if status == errno.EEXIST:
        print("Release output directory already exists.", file=sys.stderr)
        return 73
    print(f"Atomic release publication failed with errno {status}.", file=sys.stderr)
    return 70


if __name__ == "__main__":
    raise SystemExit(main())
