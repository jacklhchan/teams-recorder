#!/usr/bin/env python3
import ctypes
import errno
import os
import secrets
import stat
import sys
from pathlib import Path


RENAME_EXCL = 0x00000004
DIRECTORY_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW


class PublishError(Exception):
    def __init__(self, status: int, message: str):
        super().__init__(message)
        self.status = status


def publication_status(error_number: int) -> int:
    if error_number in (errno.EEXIST, errno.ELOOP, errno.ENOTDIR):
        return 73
    return 70


def open_directory_path(
    path: Path,
    *,
    create: bool,
    missing_status: int = 73,
) -> int:
    if not path.is_absolute():
        raise PublishError(64, "Publication paths must be absolute.")

    directory_fd = os.open("/", DIRECTORY_FLAGS)
    try:
        for component in path.parts[1:]:
            if component in ("", ".", ".."):
                raise PublishError(64, "Publication paths must be normalized.")
            try:
                next_fd = os.open(
                    component,
                    DIRECTORY_FLAGS,
                    dir_fd=directory_fd,
                )
            except FileNotFoundError:
                if not create:
                    raise PublishError(
                        missing_status,
                        "Publication directory is unavailable.",
                    )
                try:
                    os.mkdir(component, 0o755, dir_fd=directory_fd)
                except FileExistsError:
                    pass
                except OSError as error:
                    raise PublishError(
                        publication_status(error.errno),
                        "Publication directory cannot be created.",
                    ) from error
                try:
                    next_fd = os.open(
                        component,
                        DIRECTORY_FLAGS,
                        dir_fd=directory_fd,
                    )
                except OSError as error:
                    raise PublishError(
                        publication_status(error.errno),
                        "Publication path changed during creation.",
                    ) from error
            except OSError as error:
                raise PublishError(
                    publication_status(error.errno),
                    "Publication path contains an unsafe component.",
                ) from error
            os.close(directory_fd)
            directory_fd = next_fd
        return directory_fd
    except BaseException:
        os.close(directory_fd)
        raise


def ensure_directory_identity(path: Path, expected_fd: int) -> None:
    current_fd = open_directory_path(path, create=False)
    try:
        current = os.fstat(current_fd)
        expected = os.fstat(expected_fd)
        if (current.st_dev, current.st_ino) != (expected.st_dev, expected.st_ino):
            raise PublishError(
                73,
                "Publication path changed during staging.",
            )
    finally:
        os.close(current_fd)


def ensure_entry_identity(
    parent_fd: int,
    name: str,
    expected_fd: int,
    *,
    changed_message: str = "Publication source changed during staging.",
) -> None:
    try:
        current = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    except OSError as error:
        raise PublishError(73, changed_message) from error
    expected = os.fstat(expected_fd)
    if (current.st_dev, current.st_ino) != (expected.st_dev, expected.st_ino):
        raise PublishError(73, changed_message)


def copy_file(source_fd: int, destination_fd: int, name: str) -> None:
    try:
        input_fd = os.open(
            name,
            os.O_RDONLY | os.O_NOFOLLOW,
            dir_fd=source_fd,
        )
    except OSError as error:
        raise PublishError(66, "Source contains an unsafe entry.") from error
    output_fd = -1
    try:
        metadata = os.fstat(input_fd)
        if not stat.S_ISREG(metadata.st_mode):
            raise PublishError(66, "Source contains a non-regular entry.")
        output_fd = os.open(
            name,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
            stat.S_IMODE(metadata.st_mode),
            dir_fd=destination_fd,
        )
        while True:
            chunk = os.read(input_fd, 1024 * 1024)
            if not chunk:
                break
            offset = 0
            while offset < len(chunk):
                offset += os.write(output_fd, chunk[offset:])
        os.fchmod(output_fd, stat.S_IMODE(metadata.st_mode))
    except PublishError:
        raise
    except OSError as error:
        raise PublishError(70, "Release staging copy failed.") from error
    finally:
        os.close(input_fd)
        if output_fd >= 0:
            os.close(output_fd)


def copy_directory(source_fd: int, destination_fd: int) -> None:
    try:
        names = os.listdir(source_fd)
    except OSError as error:
        raise PublishError(66, "Source directory cannot be read.") from error

    for name in names:
        try:
            metadata = os.stat(
                name,
                dir_fd=source_fd,
                follow_symlinks=False,
            )
        except OSError as error:
            raise PublishError(66, "Source entry cannot be inspected.") from error
        if stat.S_ISREG(metadata.st_mode):
            copy_file(source_fd, destination_fd, name)
            continue
        if stat.S_ISDIR(metadata.st_mode):
            try:
                os.mkdir(
                    name,
                    stat.S_IMODE(metadata.st_mode),
                    dir_fd=destination_fd,
                )
                source_child = os.open(
                    name,
                    DIRECTORY_FLAGS,
                    dir_fd=source_fd,
                )
                destination_child = os.open(
                    name,
                    DIRECTORY_FLAGS,
                    dir_fd=destination_fd,
                )
            except OSError as error:
                raise PublishError(70, "Release staging copy failed.") from error
            try:
                copy_directory(source_child, destination_child)
                os.fchmod(
                    destination_child,
                    stat.S_IMODE(metadata.st_mode),
                )
            finally:
                os.close(source_child)
                os.close(destination_child)
            continue
        raise PublishError(66, "Source contains a non-regular entry.")


def remove_directory_contents(directory_fd: int) -> None:
    for name in os.listdir(directory_fd):
        metadata = os.stat(
            name,
            dir_fd=directory_fd,
            follow_symlinks=False,
        )
        if stat.S_ISDIR(metadata.st_mode):
            child_fd = os.open(
                name,
                DIRECTORY_FLAGS,
                dir_fd=directory_fd,
            )
            try:
                remove_directory_contents(child_fd)
            finally:
                os.close(child_fd)
            os.rmdir(name, dir_fd=directory_fd)
        else:
            os.unlink(name, dir_fd=directory_fd)


def rename_directory_exclusive(
    source_parent_fd: int,
    source_name: str,
    destination_parent_fd: int,
    destination_name: str,
) -> None:
    try:
        libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
        rename_exclusive = libc.renameatx_np
    except (AttributeError, OSError) as error:
        raise PublishError(
            78,
            "Atomic publication is unsupported on this host.",
        ) from error
    rename_exclusive.argtypes = [
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_uint,
    ]
    rename_exclusive.restype = ctypes.c_int
    result = rename_exclusive(
        source_parent_fd,
        os.fsencode(source_name),
        destination_parent_fd,
        os.fsencode(destination_name),
        RENAME_EXCL,
    )
    if result != 0:
        error_number = ctypes.get_errno()
        raise OSError(error_number, os.strerror(error_number))


def publish_directory(
    source: Path,
    destination: Path,
    *,
    rename_exclusive=None,
) -> None:
    source = Path(source)
    destination = Path(destination)
    if not source.is_absolute() or not destination.is_absolute():
        raise PublishError(64, "Publication paths must be absolute.")
    if source.name in ("", ".", "..") or destination.name in ("", ".", ".."):
        raise PublishError(64, "Publication paths must name directories.")

    source_parent_fd = open_directory_path(
        source.parent,
        create=False,
        missing_status=66,
    )
    source_fd = -1
    destination_parent_fd = -1
    staging_fd = -1
    staging_name = ""
    published = False
    try:
        try:
            source_fd = os.open(
                source.name,
                DIRECTORY_FLAGS,
                dir_fd=source_parent_fd,
            )
        except OSError as error:
            raise PublishError(
                66,
                "Source is not a regular directory.",
            ) from error
        destination_parent_fd = open_directory_path(
            destination.parent,
            create=True,
        )
        try:
            os.stat(
                destination.name,
                dir_fd=destination_parent_fd,
                follow_symlinks=False,
            )
        except FileNotFoundError:
            pass
        else:
            raise PublishError(
                73,
                "Release output directory already exists.",
            )

        ensure_directory_identity(source.parent, source_parent_fd)
        ensure_entry_identity(source_parent_fd, source.name, source_fd)
        ensure_directory_identity(
            destination.parent,
            destination_parent_fd,
        )

        for _attempt in range(32):
            candidate = f".lmr-release-publish.{secrets.token_hex(8)}"
            try:
                os.mkdir(candidate, 0o700, dir_fd=destination_parent_fd)
            except FileExistsError:
                continue
            staging_name = candidate
            break
        if not staging_name:
            raise PublishError(70, "Cannot allocate publication staging.")
        staging_fd = os.open(
            staging_name,
            DIRECTORY_FLAGS,
            dir_fd=destination_parent_fd,
        )
        copy_directory(source_fd, staging_fd)

        ensure_directory_identity(source.parent, source_parent_fd)
        ensure_entry_identity(source_parent_fd, source.name, source_fd)
        ensure_directory_identity(
            destination.parent,
            destination_parent_fd,
        )
        ensure_entry_identity(
            destination_parent_fd,
            staging_name,
            staging_fd,
            changed_message="Publication staging changed before publication.",
        )

        operation = rename_exclusive or rename_directory_exclusive
        try:
            operation(
                destination_parent_fd,
                staging_name,
                destination_parent_fd,
                destination.name,
            )
        except PublishError:
            raise
        except OSError as error:
            raise PublishError(
                publication_status(error.errno),
                f"Atomic release publication failed with errno {error.errno}.",
            ) from error
        published = True
        staging_name = ""

        try:
            remove_directory_contents(source_fd)
            os.close(source_fd)
            source_fd = -1
            os.rmdir(source.name, dir_fd=source_parent_fd)
        except OSError:
            pass
    finally:
        if staging_fd >= 0:
            os.close(staging_fd)
        if staging_name and destination_parent_fd >= 0:
            try:
                cleanup_fd = os.open(
                    staging_name,
                    DIRECTORY_FLAGS,
                    dir_fd=destination_parent_fd,
                )
                try:
                    remove_directory_contents(cleanup_fd)
                finally:
                    os.close(cleanup_fd)
                os.rmdir(staging_name, dir_fd=destination_parent_fd)
            except OSError:
                pass
        if source_fd >= 0:
            os.close(source_fd)
        if destination_parent_fd >= 0:
            os.close(destination_parent_fd)
        os.close(source_parent_fd)

    if not published:
        raise PublishError(70, "Atomic release publication failed.")


def main() -> int:
    if len(sys.argv) != 3:
        print(
            "Usage: atomic-publish-directory.py "
            "<source-directory> <destination-directory>",
            file=sys.stderr,
        )
        return 64
    try:
        publish_directory(Path(sys.argv[1]), Path(sys.argv[2]))
    except PublishError as error:
        print(str(error), file=sys.stderr)
        return error.status
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
