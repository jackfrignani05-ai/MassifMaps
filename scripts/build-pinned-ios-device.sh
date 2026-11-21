#!/usr/bin/env bash
set -euo pipefail

source_dir="$1"
output="$2"
pin=a3ff0f34946748522014bb19421ed72e57e51eb2
externals_pin=9b9446c85d3615275c2fa0528e914eeee30ab129
angle_pin=7ed53088120839b68f7ba4df3dac181618c037da
swig_pin=32e8175bd183438584be93a83834d4e224ef1add
test "$(uname -s):$(uname -m)" = Darwin:arm64
test "$(git -C "$source_dir" rev-parse HEAD)" = "$pin"
test ! -e "$output"
xcodebuild -version
xcrun --sdk iphoneos --show-sdk-version

export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ANALYTICS=1
for tool in autoconf automake libtool; do
  brew list --versions "$tool" >/dev/null 2>&1 || brew install "$tool"
  export PATH="$(brew --prefix "$tool")/bin:$PATH"
done

git -C "$source_dir" submodule update --init --recursive --depth 1 libs-external
test "$(git -C "$source_dir/libs-external" rev-parse HEAD)" = "$externals_pin"
test "$(git -C "$source_dir/libs-external/angle-metal" rev-parse HEAD)" = "$angle_pin"

python3 - "$source_dir/scripts/build/CMakeLists.txt" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
data = path.read_bytes()
before = b'  list(APPEND SDK_EXTERNAL_SUBPROJECTS "sqlite" "sqlite3pp")'
after = b'  list(APPEND SDK_EXTERNAL_SUBPROJECTS "sqlite3pp")'
if data.count(before) != 1:
    raise SystemExit('Unexpected pinned SQLite configuration')
path.write_bytes(data.replace(before, after))
PY

work="$(mktemp -d)"
cd "$work"
curl -fL --retry 3 -o cmake.tar.gz https://github.com/Kitware/CMake/releases/download/v3.31.6/cmake-3.31.6-macos-universal.tar.gz
printf '%s  %s\n' 330b9514f5112e5ed4fb08b8b05803b776fd9b539a6ae12927d14dcc0ee2ba8d cmake.tar.gz | shasum -a 256 -c -
tar -xzf cmake.tar.gz
cmake="$work/cmake-3.31.6-macos-universal/CMake.app/Contents/bin/cmake"

cd "$source_dir"
curl -fL --retry 3 -o boost_1_89_0.zip https://archives.boost.io/release/1.89.0/source/boost_1_89_0.zip
printf '%s  %s\n' 77bee48e32cabab96a3fd2589ec3ab9a17798d330220fdd8bde6ff5611b4ccde boost_1_89_0.zip | shasum -a 256 -c -
unzip -q boost_1_89_0.zip
ln -s "$source_dir/boost_1_89_0" "$source_dir/libs-external/boost"
(cd boost_1_89_0 && ./bootstrap.sh && ./b2 headers)

swig_dir="$work/mobile-swig"
git init "$swig_dir"
git -C "$swig_dir" remote add origin https://github.com/massif-maps/mobile-swig.git
git -C "$swig_dir" fetch --depth 1 origin "$swig_pin"
git -C "$swig_dir" switch --detach FETCH_HEAD
test "$(git -C "$swig_dir" rev-parse HEAD)" = "$swig_pin"
cd "$swig_dir"
curl -fL --retry 3 -o pcre2-10.44.tar.gz https://github.com/PCRE2Project/pcre2/releases/download/pcre2-10.44/pcre2-10.44.tar.gz
printf '%s  %s\n' 86b9cb0aa3bcb7994faa88018292bc704cdbb708e785f7c74352ff6ea7d3175b pcre2-10.44.tar.gz | shasum -a 256 -c -
./Tools/pcre-build.sh
./autogen.sh
./configure
make -j"$(sysctl -n hw.ncpu)"

cd "$source_dir/scripts"
python3 swigpp-objc.py --profile full --swig "$swig_dir/swig"
python3 build-ios.py --profile full --configuration Release --build-version 0.0.0-a3ff0f3 \
  --build-xcframework --use-metalangle --strip-bitcode --ios-arch arm64 --cmake "$cmake"

framework="$source_dir/dist/ios_metal/MassifMaps.xcframework"
library="$framework/ios-arm64/MassifMaps.a"
angle="$source_dir/libs-external/angle-metal/arm64/libangle.a"
test "$(xcrun lipo -archs "$library")" = arm64
test "$(xcrun lipo -archs "$angle")" = arm64
imports="$(xcrun nm -j -u "$library")"
grep -Eq '^_sqlite3_open(_v2)?$' <<< "$imports"
if grep -Eq '^_(f?statfs|f?statvfs)(64|\$[A-Z0-9_]+)?$' <<< "$imports"; then
  printf '%s\n' 'Unexpected disk-space import in Massif' >&2
  exit 2
fi
definitions="$(xcrun nm -g -j -U "$library")"
if grep -Eq '^_sqlite3_open(_v2)?$' <<< "$definitions"; then
  printf '%s\n' 'Unexpected statically bundled SQLite in Massif' >&2
  exit 2
fi
for archive in "$library" "$angle"; do
  xcrun otool -l "$archive" | awk '
    $1 == "platform" { if (tolower($2) == "ios" || $2 == "2") found = 1; else incompatible = 1 }
    $1 == "cmd" && $2 == "LC_VERSION_MIN_IPHONEOS" { found = 1 }
    $1 == "cmd" && $2 ~ /^LC_VERSION_MIN_(MACOSX|TVOS|WATCHOS)$/ { incompatible = 1 }
    END { exit (!found || incompatible) }
  '
done

mkdir -p "$output/MetalANGLE/arm64"
ditto "$framework" "$output/MassifMaps-a3ff0f3.xcframework"
cp "$angle" "$output/MetalANGLE/arm64/libangle.a"
python3 - "$output" "$pin" "$externals_pin" "$angle_pin" "$swig_pin" <<'PY'
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import sys

output, pin, externals, angle, swig = sys.argv[1:]
root = Path(output)
framework = root / 'MassifMaps-a3ff0f3.xcframework'
with (framework / 'Info.plist').open('rb') as file:
    libraries = plistlib.load(file).get('AvailableLibraries', [])
if len(libraries) != 1:
    raise SystemExit('Expected a single device slice')
item = libraries[0]
if (item.get('LibraryIdentifier') != 'ios-arm64' or item.get('LibraryPath') != 'MassifMaps.a'
        or item.get('SupportedArchitectures') != ['arm64'] or item.get('SupportedPlatform') != 'ios'
        or item.get('SupportedPlatformVariant') is not None):
    raise SystemExit('Invalid device slice')
headers = framework / 'ios-arm64' / item['HeadersPath']
if not (headers / 'MassifMaps/MSFMassifApi.h').is_file() or not (headers / 'module.modulemap').is_file():
    raise SystemExit('Missing Objective-C bindings or module map')

def digest(path):
    sha = hashlib.sha256()
    with path.open('rb') as file:
        for block in iter(lambda: file.read(1024 * 1024), b''):
            sha.update(block)
    return sha.hexdigest()

report = {
    'source_revision': pin,
    'externals_revision': externals,
    'metalangle_revision': angle,
    'swig_revision': swig,
    'configuration': 'Release',
    'profile': 'full',
    'architectures': ['arm64'],
    'device_core_available': True,
    'sqlite_linkage': 'system',
    'library_sha256': digest(framework / 'ios-arm64/MassifMaps.a'),
    'metalangle_sha256': digest(root / 'MetalANGLE/arm64/libangle.a'),
    'xcode': subprocess.check_output(['xcodebuild', '-version'], text=True).strip(),
    'sdk_version': subprocess.check_output(
        ['xcrun', '--sdk', 'iphoneos', '--show-sdk-version'], text=True,
    ).strip(),
}
(root / 'massif-sdk-provenance.json').write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
files = sorted(path for path in root.rglob('*') if path.is_file())
(root / 'SHA256SUMS').write_text(
    ''.join(f'{digest(path)}  {path.relative_to(root).as_posix()}\n' for path in files),
    encoding='utf-8',
)
print(json.dumps(report, indent=2))
PY
