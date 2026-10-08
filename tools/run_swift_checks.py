#!/usr/bin/env python3
"""Compile and run standalone ScreenTake checks against the current app sources."""
import argparse
import platform
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("checks", nargs="*", default=["test_editor_session.swift"])
    parser.add_argument("--render-only", action="store_true", help="Skip optional screenshot checks in tests that support this flag")
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    with tempfile.TemporaryDirectory(prefix="screentake-checks-") as temporary:
        build = Path(temporary)
        app = build / "TestApp.swift"
        app.write_text((root / "Screen/App/ScreenApp.swift").read_text().replace("@main\n", ""))
        exception_object = build / "exceptions.o"
        subprocess.run(["xcrun", "clang", "-target", f"{platform.machine()}-apple-macosx13.0", "-c",
                        str(root / "Screen/Core/Recording/ObjCExceptionCatcher.m"),
                        "-o", str(exception_object)], check=True, cwd=root)
        sources = sorted(str(p) for p in (root / "Screen").rglob("*.swift") if p.name != "ScreenApp.swift")
        for name in args.checks:
            check = root / name
            if check.parent != root or not check.name.startswith("test_") or check.suffix != ".swift" or not check.is_file():
                parser.error(f"Expected a test_*.swift file in the project root: {name}")
            executable = build / check.stem
            command = ["xcrun", "swiftc", "-parse-as-library", "-swift-version", "5",
                       "-target", f"{platform.machine()}-apple-macosx13.0",
                       "-module-cache-path", str(build / "module-cache")]
            if check.name == "test_video_trim.swift":
                command += [str(root / "Screen/Core/Recording/MediaMuxer.swift"), str(root / "Screen/App/Log.swift")]
            else:
                command += ["-I", str(root / "Screen/Core/Recording"), "-import-objc-header",
                            str(root / "Screen/Screen-Bridging-Header.h"), *sources, str(app), str(exception_object)]
            print(f"Compiling {check.name}…", flush=True)
            subprocess.run([*command, str(check), "-o", str(executable)], check=True, cwd=root)
            print(f"Running {check.name}…", flush=True)
            subprocess.run([str(executable), *(["--render-only"] if args.render_only else [])], check=True, cwd=root)


if __name__ == "__main__":
    main()
