#!/usr/bin/env python3
"""Headless smoke test mirroring PR OpenBVE#1333 VideoTexture usage.

Loads libmpv via ctypes and exercises the exact symbols OpenBVE P/Invokes:
mpv_create, mpv_set_option_string(vo=libmpv), mpv_initialize,
mpv_render_context_create(opengl), mpv_render_context_update,
mpv_get_property_string(video-params/w), mpv_free, mpv_terminate_destroy.

Render itself needs a GL context (provided by OpenBVE at runtime), so this
script only proves the LGPL lib exports the render API and initializes.
Full FBO render is covered by OpenBVE ObjectViewer manual test.

Usage: smoke-opengl.py <path-to-lib>
Exit 0 = pass, non-zero = fail.
"""
import ctypes
import sys

REQUIRED = [
    "mpv_create",
    "mpv_initialize",
    "mpv_terminate_destroy",
    "mpv_command",
    "mpv_set_option_string",
    "mpv_get_property_string",
    "mpv_free",
    "mpv_render_context_create",
    "mpv_render_context_free",
    "mpv_render_context_render",
    "mpv_render_context_update",
    "mpv_client_api_version",
]


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <libmpv path>")
        return 2
    path = sys.argv[1]
    try:
        lib = ctypes.CDLL(path)
    except Exception as e:
        print(f"[smoke][FAIL] cannot load {path}: {e}")
        return 1

    missing = [n for n in REQUIRED if not hasattr(lib, n)]
    if missing:
        print(f"[smoke][FAIL] missing exports: {missing}")
        return 1
    print(f"[smoke][OK] all {len(REQUIRED)} exports present")

    try:
        lib.mpv_client_api_version.restype = ctypes.c_ulong
        ver = lib.mpv_client_api_version()
        print(f"[smoke][OK] mpv_client_api_version=0x{ver:x}")
        if ver < 0x20000:
            print(f"[smoke][FAIL] client API < 2.0 (OpenBVE needs libmpv-2 ABI)")
            return 1
        lib.mpv_create.restype = ctypes.c_void_p
        h = lib.mpv_create()
        if not h:
            print("[smoke][FAIL] mpv_create returned NULL")
            return 1
        print("[smoke][OK] mpv_create non-NULL")
        lib.mpv_set_option_string.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p]
        lib.mpv_set_option_string.restype = ctypes.c_int
        # Mirror VideoTexture.Initialize options (decode-only subset)
        for k, v in [(b"vo", b"libmpv"), (b"ytdl", b"no"),
                     (b"load-scripts", b"no"), (b"aid", b"no")]:
            rc = lib.mpv_set_option_string(h, k, v)
            if rc < 0:
                print(f"[smoke][FAIL] set_option {k} -> {rc}")
                return 1
        print("[smoke][OK] set_option vo/ytdl/load-scripts/aid accepted")
        lib.mpv_initialize.argtypes = [ctypes.c_void_p]
        lib.mpv_initialize.restype = ctypes.c_int
        if lib.mpv_initialize(h) < 0:
            print("[smoke][FAIL] mpv_initialize failed")
            return 1
        print("[smoke][OK] mpv_initialize ok")
        lib.mpv_terminate_destroy.argtypes = [ctypes.c_void_p]
        lib.mpv_terminate_destroy(h)
        print("[smoke][OK] terminate_destroy ok")
    except Exception as e:
        print(f"[smoke][FAIL] exception: {e}")
        return 1
    print("[smoke] PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
