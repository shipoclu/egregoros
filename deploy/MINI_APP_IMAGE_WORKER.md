# Mini-app image worker deployment

Mini-app card images are attacker-controlled bytes. Egregoros never opens them
with `Image`, Vix, or libvips in the application BEAM. It invokes a disposable
ImageMagick process through the bundled `priv/mini_app_image_worker.py`
launcher, then serves only the worker's validated, single-frame WebP output.

The supplied Docker image installs the three runtime dependencies:

- Python 3 (`python3-minimal`) for the resource-limit launcher;
- ImageMagick (`imagemagick`) for the one-shot decoder/encoder;
- the `procps` package, which supplies the external `kill` command used to
  terminate and reap the worker process group.

It also creates the mode-0700 `/data/miniapp-images` parent and selects it with
`EGREGOROS_MINI_APP_IMAGE_TMP_DIR`.

An installation outside Docker must provide Python 3, either the `magick`
(ImageMagick 7) or `convert` (ImageMagick 6) executable, and the system `kill`
executable. Egregoros resolves absolute executable paths at request time and
fails closed with no image when one is absent or not executable. Production
image processing is supported on Linux. Other Unix hosts deliberately fail
before the readiness handshake when they cannot apply every required hard
resource limit; images fail closed instead of falling back to an in-process
decoder.

Paths may be pinned explicitly:

```text
EGREGOROS_MINI_APP_IMAGE_PYTHON=/usr/bin/python3
EGREGOROS_MINI_APP_IMAGE_DECODER=/usr/bin/convert
EGREGOROS_MINI_APP_IMAGE_KILL=/bin/kill
EGREGOROS_MINI_APP_IMAGE_TMP_DIR=/var/tmp/egregoros-miniapp-images
```

The temporary directory must already exist, be absolute, and be writable only
by the Egregoros service account. Do not place it below the static-file root or
uploads directory. Each request receives a random mode-0700 child directory;
the input is mode 0600 and the entire child directory is removed after success,
failure, crash, or timeout.

## Enforced boundary

Before pixel decoding, Egregoros itself caps the compressed body at 5 MB,
checks the declared MIME type against a byte signature, rejects malformed PNG
chunk structure/CRC, caps PNG/WebP container work at 1,024 chunks, rejects
PNG/WebP/AVIF animation markers, and enforces
10,000-pixel dimensions and 10-megapixel area wherever the container exposes
them safely.

The worker starts in its own process group, receives no Egregoros environment
variables, and applies hard OS limits before it replaces itself with
ImageMagick:

- 768 MiB virtual address space;
- four CPU seconds and six wall-clock seconds;
- a 5 MB output-file limit;
- 32 open files;
- no child process or additional thread creation (`RLIMIT_NPROC=1`);
- no core dumps.

The bundled ImageMagick policy independently limits memory/map caches to 128
MiB each, disables disk-backed pixel caches, permits one thread, caps the
decoder's internal image list, width, height, and area, denies delegates and filters, and denies every
coder/module except read-only PNG, JPEG, WebP, AVIF/HEIC and WebP output. The
parent caps worker diagnostics at 4 KiB, validates output size/signature/static
structure again, and sends `SIGKILL` to the worker process group on timeout or
abnormal completion. The two-slot supervised pool bounds concurrent decoders.

Do not loosen or replace `priv/mini_app_image_policy/policy.xml` without a new
adversarial review. Keep ImageMagick and the OS patched. These controls contain
native crashes and resource exhaustion outside the application VM. They are
not a substitute for a separately isolated image-processing sidecar when the
deployment threat model assumes arbitrary code execution inside a fully
compromised decoder: the disposable worker still begins under the Egregoros OS
uid. A high-assurance deployment should run Egregoros's worker protocol in a
dedicated container/VM with no network, a read-only filesystem, and only its
per-request input/output directory mounted.

## Deployment check

After every base-image or ImageMagick upgrade:

1. Confirm `python3` and the configured decoder resolve to absolute executable
   paths inside the running release container.
2. Run `magick -list policy` (or `convert -list policy`) with
   `MAGICK_CONFIGURE_PATH` pointing at the release's
   `priv/mini_app_image_policy` directory and confirm the deny rules and limits
   are present.
3. Exercise a mini-app card using a valid PNG, an animated WebP, a truncated
   image, and an over-dimension PNG. Only the valid PNG may render.
4. Confirm timed-out worker PIDs and `egregoros-miniapp-image-*` temporary
   directories do not remain.
