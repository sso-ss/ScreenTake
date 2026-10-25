#!/usr/bin/env python3
"""Compile optimized checks from the app's actual Xcode source list, then sign.
Run from the repository root after a signed app build. No preferences or media
outside the check's own output directory are modified.
"""
from pathlib import Path
import plistlib, shlex, shutil, subprocess
root = Path.cwd()
work = root / '.build/soft-peach-integration'
products = root / '.build/DerivedData/Build/Products/Release'
intermediates = root / '.build/DerivedData/Build/Intermediates.noindex/Screen.build/Release/Screen.build/Objects-normal/arm64'
app = work / 'Checks.app'
(app / 'Contents/MacOS').mkdir(parents=True, exist_ok=True)
for folder in ['Resources', 'Frameworks']:
    destination = app / 'Contents' / folder
    if destination.exists(): shutil.rmtree(destination)
    shutil.copytree(products / 'ScreenTake.app/Contents' / folder, destination, symlinks=True)
(app / 'Contents/Info.plist').write_bytes(plistlib.dumps(dict(CFBundleExecutable='Checks', CFBundleIdentifier='studio.screentake.checks.integration', CFBundlePackageType='APPL')))
checks = []
for name in ['test_face_effects.swift', 'test_face_beauty_export.swift', 'test_face_effect_playback.swift']:
    path = root / 'Tests' / name
    if not path.exists(): continue
    source = path.read_text().replace('@testable import ScreenTake', '').replace('@main', '')
    if name == 'test_face_beauty_export.swift':
        source = source.replace('CheckFailure', 'ExportCheckFailure').replace('require(', 'requireExport(')
    target = work / name
    target.write_text(source)
    checks.append(str(target))
entry = work / 'CheckMain.swift'
entry.write_text('''import Foundation
@main struct CheckMain {
    @MainActor static func main() async {
        switch ProcessInfo.processInfo.environment["SCREENTAKE_CHECK"] {
        case "export": await BeautyExportChecks.main()
        case "playback": await FaceEffectPlaybackChecks.main()
        default: FaceEffectsChecks.main()
        }
    }
}
''')
sources = shlex.split((intermediates / 'ScreenTake.SwiftFileList').read_text())
sources = [p for p in sources if not p.endswith('/ScreenApp.swift')]
command = ['xcrun', 'swiftc', '-parse-as-library', '-O', '-whole-module-optimization', '-num-threads', '8', '-swift-version', '5', '-D', 'SCREENTAKE_RUNTIME', '-module-name', 'ScreenTake', '-target', 'arm64-apple-macosx13.0', '-module-cache-path', str(work / 'module-cache'), '-import-objc-header', str(root / 'Screen/Screen-Bridging-Header.h'), '-I', str(root / 'Screen/Core/Recording'), '-F', str(products / 'PackageFrameworks'), '-F', str(products), '-Xlinker', '-rpath', '-Xlinker', '@executable_path/../Frameworks', *sources, *checks, str(entry), str(intermediates / 'ObjCExceptionCatcher.o'), '-o', str(app / 'Contents/MacOS/Checks')]
subprocess.run(command, check=True)
subprocess.run(['codesign', '--force', '--sign', 'Developer ID Application: So Eun Ahn (43LSH32H5S)', '--timestamp=none', str(app)], check=True)
print(app / 'Contents/MacOS/Checks', flush=True)
