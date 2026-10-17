#!/usr/bin/env python3
"""Build the pinned Chiaki C core and its complete static dependency closure.

Requires Xcode command line tools, CMake, Ninja, pkg-config, Perl and make.
No console connections are made. Use --config to obtain app integration paths.
"""
import argparse
import hashlib
import json
import os
import platform
import shutil
import subprocess
import sys
from pathlib import Path

from bootstrap import ROOT, prepare_remoteplay


def configuration(arch):
    prefix = ROOT / ".deps/remoteplay" / arch / "install"
    names = ["chiaki", "protobuf-nanopb", "jerasure", "gf_complete", "opus", "json-c",
             "miniupnpc", "event", "curl", "ssl", "crypto"]
    return {"architecture": arch, "deployment_target": "14.0", "prefix": str(prefix),
            "include_dirs": [str(prefix / "include")],
            "libraries": [str(prefix / "lib" / f"lib{name}.a") for name in names],
            "frameworks": ["CoreServices", "SystemConfiguration"]}


def run(command, *, cwd=None, env=None):
    print("+ " + " ".join(map(str, command)), flush=True)
    subprocess.run(list(map(str, command)), cwd=cwd, env=env, check=True)


def clean_environment():
    env = os.environ.copy()
    for name in ("CFLAGS", "CPPFLAGS", "CXXFLAGS", "LDFLAGS", "CPATH", "C_INCLUDE_PATH",
                 "CPLUS_INCLUDE_PATH", "LIBRARY_PATH", "CMAKE_PREFIX_PATH", "PKG_CONFIG_SYSROOT_DIR"):
        env.pop(name, None)
    return env


def cmake_build(source, build, prefix, arch, env, jobs, flags=(), target=None):
    run(["cmake", "-S", source, "-B", build, "-G", "Ninja", "-DCMAKE_BUILD_TYPE=Release",
         "-DBUILD_SHARED_LIBS=OFF", "-DCMAKE_POSITION_INDEPENDENT_CODE=ON",
         f"-DCMAKE_INSTALL_PREFIX={prefix}", "-DCMAKE_INSTALL_LIBDIR=lib",
         f"-DCMAKE_OSX_ARCHITECTURES={arch}", "-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0",
         f"-DCMAKE_PREFIX_PATH={prefix}", "-DCMAKE_IGNORE_PREFIX_PATH=/opt/homebrew;/usr/local",
         f"-DCMAKE_C_COMPILER={env['CC']}", *flags], env=env)
    command = ["cmake", "--build", build, "--parallel", str(jobs)]
    if target:
        command += ["--target", target]
    run(command, env=env)
    if target is None:
        run(["cmake", "--install", build], env=env)


def verify(config, build, env):
    """Force session/registration/Opus object files into an executable and audit it."""
    prefix = Path(config["prefix"])
    source = build / "link-smoke.c"
    source.write_text('''#include <chiaki/session.h>
#include <chiaki/regist.h>
#include <chiaki/opusdecoder.h>
int main(int argc, char **argv) {
    (void)argv;
    if (argc == 12345) {
        ChiakiSession session;
        ChiakiConnectInfo info = {0};
        ChiakiRegist regist;
        ChiakiRegistInfo ri = {0};
        ChiakiOpusDecoder decoder;
        chiaki_session_init(&session, &info, 0);
        chiaki_session_fini(&session);
        chiaki_regist_start(&regist, 0, &ri, 0, 0);
        chiaki_regist_stop(&regist);
        chiaki_regist_fini(&regist);
        chiaki_opus_decoder_init(&decoder, 0);
        chiaki_opus_decoder_fini(&decoder);
    }
    return chiaki_lib_init() == CHIAKI_ERR_SUCCESS ? 0 : 1;
}
''')
    executable = build / "link-smoke"
    frameworks = [arg for name in config["frameworks"] for arg in ("-framework", name)]
    run([env["CC"], "-arch", config["architecture"], "-mmacosx-version-min=14.0",
         "-I", prefix / "include", source, *config["libraries"], *frameworks, "-o", executable], env=env)
    linked = subprocess.check_output(["otool", "-L", executable], text=True)
    for line in linked.splitlines()[1:]:
        dependency = line.strip().split(" (", 1)[0]
        if not dependency.startswith(("/usr/lib/", "/System/Library/")):
            raise SystemExit(f"Non-system dynamic dependency: {dependency}")
    (build / "otool.txt").write_text(linked)
    for library in config["libraries"]:
        result = subprocess.check_output(["lipo", "-archs", library], text=True).strip()
        if result != config["architecture"]:
            raise SystemExit(f"Wrong archive architecture: {library}: {result}")
    # Cross-built Intel binaries need Rosetta to run; native builds always execute.
    if config["architecture"] == platform.machine():
        run([executable], env=env)
    print(linked, end="")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--arch", choices=("arm64", "x86_64"), default=platform.machine())
    parser.add_argument("--jobs", type=int, default=os.cpu_count() or 4)
    parser.add_argument("--config", action="store_true", help="print integration paths as JSON without building")
    args = parser.parse_args()
    config = configuration(args.arch)
    if args.config:
        print(json.dumps(config, indent=2))
        return
    if sys.platform != "darwin":
        raise SystemExit("The Remote Play app build currently supports macOS only")
    if args.jobs < 1:
        parser.error("--jobs must be positive")
    prepare_remoteplay()
    sources = ROOT / ".deps/remoteplay/sources"
    base = ROOT / ".deps/remoteplay" / args.arch
    build = base / "build"
    prefix = Path(config["prefix"])
    build.mkdir(parents=True, exist_ok=True)
    prefix.mkdir(parents=True, exist_ok=True)
    env = clean_environment()
    env["CC"] = subprocess.check_output(["xcrun", "--find", "clang"], text=True).strip()
    env["SDKROOT"] = subprocess.check_output(["xcrun", "--show-sdk-path"], text=True).strip()
    env["MACOSX_DEPLOYMENT_TARGET"] = "14.0"
    env["PKG_CONFIG_LIBDIR"] = str(prefix / "lib/pkgconfig")
    env["PKG_CONFIG_PATH"] = ""
    env["PYTHONPATH"] = str(sources / "protobuf-python")
    env["PATH"] = str(sources / "protoc/bin") + os.pathsep + env["PATH"]
    env["NANOPB_PB2_TEMP_DIR"] = str(build)
    fingerprint = hashlib.sha256((ROOT / "toolchain.lock.json").read_bytes() +
                                 Path(__file__).read_bytes() + args.arch.encode()).hexdigest()
    marker = prefix / ".ps5mcp-build"
    cached = marker.exists() and marker.read_text().strip() == fingerprint
    if not cached or not all(Path(p).is_file() for p in config["libraries"]):
        openssl_build = build / "openssl"
        openssl_build.mkdir(exist_ok=True)
        target = "darwin64-arm64-cc" if args.arch == "arm64" else "darwin64-x86_64-cc"
        run([sources / "openssl/Configure", target, "no-shared", "no-module", "no-tests", "no-zlib",
             f"--prefix={prefix}", "--libdir=lib", "-mmacosx-version-min=14.0"], cwd=openssl_build, env=env)
        run(["make", f"-j{args.jobs}"], cwd=openssl_build, env=env)
        run(["make", "install_sw"], cwd=openssl_build, env=env)
        dependencies = {
            "opus": ["-DOPUS_BUILD_TESTING=OFF", "-DOPUS_BUILD_PROGRAMS=OFF"],
            "json-c": ["-DBUILD_TESTING=OFF", "-DBUILD_APPS=OFF", "-DDISABLE_EXTRA_LIBS=ON"],
            "miniupnpc": ["-DUPNPC_BUILD_SHARED=OFF", "-DUPNPC_BUILD_TESTS=OFF", "-DUPNPC_BUILD_SAMPLE=OFF"],
            "libevent": ["-DEVENT__LIBRARY_TYPE=STATIC", "-DEVENT__DISABLE_OPENSSL=ON",
                         "-DEVENT__DISABLE_TESTS=ON", "-DEVENT__DISABLE_REGRESS=ON",
                         "-DEVENT__DISABLE_SAMPLES=ON", "-DEVENT__DISABLE_BENCHMARK=ON"],
        }
        for name, flags in dependencies.items():
            cmake_build(sources / name, build / name, prefix, args.arch, env, args.jobs, flags)
        flags = [f"-D{option}=OFF" for option in (
            "CHIAKI_ENABLE_TESTS", "CHIAKI_ENABLE_CLI", "CHIAKI_ENABLE_GUI", "CHIAKI_ENABLE_SETSU",
            "CHIAKI_ENABLE_STEAMDECK_NATIVE", "CHIAKI_ENABLE_SPEEX", "CHIAKI_ENABLE_RUDP",
            "CHIAKI_ENABLE_FFMPEG_DECODER", "CHIAKI_ENABLE_PI_DECODER", "CHIAKI_ENABLE_STEAM_SHORTCUT",
            "CHIAKI_USE_SYSTEM_JERASURE", "CHIAKI_USE_SYSTEM_NANOPB", "CHIAKI_USE_SYSTEM_CURL",
            "CURL_USE_LIBPSL", "CURL_USE_LIBSSH2", "USE_LIBIDN2", "CURL_BROTLI", "CURL_ZSTD",
            "CURL_ZLIB", "CURL_USE_SECTRANSP", "NANOPB_BUILD_GENERATOR")]
        flags += ["-DCHIAKI_LIB_ENABLE_OPUS=ON", "-DOPENSSL_USE_STATIC_LIBS=TRUE", "-DCURL_USE_OPENSSL=ON",
                  f"-DOPENSSL_ROOT_DIR={prefix}", f"-DOPENSSL_INCLUDE_DIR={prefix}/include",
                  f"-DOPENSSL_CRYPTO_LIBRARY={prefix}/lib/libcrypto.a",
                  f"-DOPENSSL_SSL_LIBRARY={prefix}/lib/libssl.a",
                  f"-DOpus_INCLUDE_DIRS={prefix}/include", f"-DOpus_LIBRARIES={prefix}/lib/libopus.a",
                  f"-DPYTHON_EXECUTABLE={sys.executable}", f"-DPROTOC={sources}/protoc/bin/protoc",
                  f"-Dnanopb_PROTOC_PATH={sources}/protoc/bin/protoc"]
        chiaki = ROOT / "third-party/chiaki-ng"
        cmake_build(chiaki, build / "chiaki", prefix, args.arch, env, args.jobs, flags, "chiaki-lib")
        archives = {"lib/libchiaki.a": "libchiaki.a", "third-party/libjerasure.a": "libjerasure.a",
                    "third-party/libgf_complete.a": "libgf_complete.a",
                    "third-party/nanopb/libprotobuf-nanopb.a": "libprotobuf-nanopb.a",
                    "third-party/curl/lib/libcurl.a": "libcurl.a"}
        for source, name in archives.items():
            shutil.copy2(build / "chiaki" / source, prefix / "lib" / name)
        shutil.copytree(chiaki / "lib/include/chiaki", prefix / "include/chiaki", dirs_exist_ok=True)
        shutil.copy2(build / "chiaki/lib/include/chiaki/config.h", prefix / "include/chiaki/config.h")
        shutil.copytree(chiaki / "third-party/curl/include/curl", prefix / "include/curl", dirs_exist_ok=True)
        marker.write_text(fingerprint + "\n")
    verify(config, build, env)
    (base / "build-config.json").write_text(json.dumps(config, indent=2) + "\n")
    print(f"Verified static Remote Play core ({args.arch}): {prefix}")


if __name__ == "__main__":
    main()
