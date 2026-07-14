#!/usr/bin/python3
"""One-shot resource-limit launcher for mini-app image sanitization."""

import os
import resource
import signal
import sys


ADDRESS_SPACE_BYTES = 768 * 1024 * 1024
CPU_SECONDS = 4
OUTPUT_BYTES = 5_000_000
OPEN_FILES = 32
WALL_SECONDS = 6
FORMATS = {"PNG", "JPEG", "WEBP", "AVIF"}
DECODERS = {"magick", "convert"}


def die(_signal, _frame):
    os.killpg(os.getpgrp(), signal.SIGKILL)


def set_limit(name, soft, hard=None):
    limit = getattr(resource, name, None)
    if limit is None:
        raise RuntimeError(f"missing required rlimit {name}")
    requested_hard = soft if hard is None else hard
    current_soft, current_hard = resource.getrlimit(limit)
    if current_hard != resource.RLIM_INFINITY:
        requested_hard = min(requested_hard, current_hard)
    requested_soft = min(soft, requested_hard)
    if current_soft != resource.RLIM_INFINITY:
        requested_soft = min(requested_soft, current_soft)
    resource.setrlimit(limit, (requested_soft, requested_hard))


def inside(directory, path):
    return os.path.commonpath((directory, path)) == directory


def main():
    if os.name != "posix" or len(sys.argv) != 7:
        return 70

    decoder, policy_dir, work_dir, image_format, input_path, output_path = sys.argv[1:]
    decoder_name = os.path.basename(decoder)
    decoder = os.path.realpath(decoder)
    policy_dir = os.path.realpath(policy_dir)
    work_dir = os.path.realpath(work_dir)
    input_path = os.path.realpath(input_path)
    output_path = os.path.realpath(output_path)

    if (
        decoder_name not in DECODERS
        or image_format not in FORMATS
        or not all(os.path.isabs(path) for path in (decoder, policy_dir, work_dir, input_path, output_path))
        or not inside(work_dir, input_path)
        or not inside(work_dir, output_path)
        or not os.path.isfile(input_path)
        or os.path.exists(output_path)
    ):
        return 70

    if os.getpgrp() != os.getpid():
        os.setsid()
    os.umask(0o077)
    set_limit("RLIMIT_CORE", 0)
    set_limit("RLIMIT_CPU", CPU_SECONDS)
    set_limit("RLIMIT_FSIZE", OUTPUT_BYTES)
    set_limit("RLIMIT_NOFILE", OPEN_FILES)
    set_limit("RLIMIT_AS", ADDRESS_SPACE_BYTES)
    set_limit("RLIMIT_NPROC", 1)

    signal.signal(signal.SIGALRM, die)
    signal.signal(signal.SIGTERM, die)
    signal.signal(signal.SIGINT, die)
    signal.alarm(WALL_SECONDS)

    sys.stdout.write("READY\n")
    sys.stdout.flush()

    environment = {
        "HOME": work_dir,
        "LANG": "C",
        "LC_ALL": "C",
        "MAGICK_AREA_LIMIT": "10MP",
        "MAGICK_CONFIGURE_PATH": policy_dir,
        "MAGICK_DISK_LIMIT": "0",
        "MAGICK_FILE_LIMIT": "16",
        "MAGICK_MAP_LIMIT": "128MiB",
        "MAGICK_MEMORY_LIMIT": "128MiB",
        "MAGICK_TEMPORARY_PATH": work_dir,
        "MAGICK_THREAD_LIMIT": "1",
        "MAGICK_TIME_LIMIT": str(CPU_SECONDS),
        "OMP_NUM_THREADS": "1",
        "TMPDIR": work_dir,
    }

    arguments = [
        decoder,
        "-quiet",
        "-limit",
        "area",
        "10MP",
        "-limit",
        "memory",
        "128MiB",
        "-limit",
        "map",
        "128MiB",
        "-limit",
        "disk",
        "0",
        "-limit",
        "file",
        "16",
        "-limit",
        "thread",
        "1",
        "-limit",
        "time",
        str(CPU_SECONDS),
        "-define",
        f"registry:temporary-path={work_dir}",
        f"{image_format}:{input_path}[0]",
        "-auto-orient",
        "-strip",
        "-colorspace",
        "sRGB",
        "-quality",
        "85",
        "-define",
        "webp:method=4",
        f"WEBP:{output_path}",
    ]

    os.execve(decoder, arguments, environment)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except BaseException:
        sys.exit(70)
