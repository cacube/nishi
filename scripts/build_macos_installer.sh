#!/bin/bash
set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repository_root=$(cd "$script_dir/.." && pwd)
cd "$repository_root"

version=''
output_directory="$repository_root/build/installers"
skip_flutter_build=false
architecture=native
dart_arm64=${LC_DART_ARM64:-}
dart_x64=${LC_DART_X64:-}

usage() {
  cat <<'EOF'
Usage: scripts/build_macos_installer.sh [options]

Options:
  --version VERSION    Override the version read from pubspec.yaml.
  --output DIRECTORY  Write the package to DIRECTORY.
  --skip-flutter-build
                       Reuse an existing macOS release application.
  --architecture VALUE
                       native (default), arm64, x64, or universal.
  --dart-arm64 PATH    arm64 Dart executable used for AOT compilation.
  --dart-x64 PATH      x64 Dart executable used for AOT compilation.
  -h, --help           Show this help.

The Dart SDK only ships an AOT backend for its own macOS architecture.
Universal output therefore requires both SDK architectures. LC_DART_ARM64 and
LC_DART_X64 provide the same values as the corresponding command options.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --version)
      [ "$#" -ge 2 ] || { echo '--version requires a value' >&2; exit 64; }
      version=$2
      shift 2
      ;;
    --output)
      [ "$#" -ge 2 ] || { echo '--output requires a value' >&2; exit 64; }
      output_directory=$2
      shift 2
      ;;
    --skip-flutter-build)
      skip_flutter_build=true
      shift
      ;;
    --architecture)
      [ "$#" -ge 2 ] || { echo '--architecture requires a value' >&2; exit 64; }
      architecture=$2
      shift 2
      ;;
    --dart-arm64)
      [ "$#" -ge 2 ] || { echo '--dart-arm64 requires a value' >&2; exit 64; }
      dart_arm64=$2
      shift 2
      ;;
    --dart-x64)
      [ "$#" -ge 2 ] || { echo '--dart-x64 requires a value' >&2; exit 64; }
      dart_x64=$2
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 64
      ;;
  esac
done

host_architecture=$(/usr/bin/uname -m)
case "$host_architecture" in
  arm64) native_architecture=arm64 ;;
  x86_64) native_architecture=x64 ;;
  *)
    echo "Unsupported macOS host architecture: $host_architecture" >&2
    exit 1
    ;;
esac
if [ "$architecture" = native ]; then
  architecture=$native_architecture
fi
case "$architecture" in
  arm64|x64|universal) ;;
  *)
    echo "Unsupported package architecture: $architecture" >&2
    exit 64
    ;;
esac

if [ -z "$version" ]; then
  version=$(/usr/bin/awk '/^version:[[:space:]]*/ { value=$2; sub(/\+.*/, "", value); print value; exit }' pubspec.yaml)
fi
case "$version" in
  ''|*[!0-9A-Za-z.-]*)
    echo "Invalid package version: $version" >&2
    exit 64
    ;;
esac

if [ ! -f bin/lc.dart ]; then
  echo 'bin/lc.dart is missing. Implement the CLI before building the installer.' >&2
  exit 1
fi

host_dart=$(command -v dart || true)
if [ -n "$host_dart" ]; then
  dart_platform=$("$host_dart" --version 2>&1 || true)
  case "$dart_platform" in
    *'macos_arm64'*)
      if [ -z "$dart_arm64" ]; then dart_arm64=$host_dart; fi
      ;;
    *'macos_x64'*)
      if [ -z "$dart_x64" ]; then dart_x64=$host_dart; fi
      ;;
  esac
fi
if { [ "$architecture" = arm64 ] || [ "$architecture" = universal ]; } &&
   { [ -z "$dart_arm64" ] || [ ! -x "$dart_arm64" ]; }; then
  echo 'An arm64 Dart SDK is required. Set LC_DART_ARM64 or pass --dart-arm64.' >&2
  exit 1
fi
if { [ "$architecture" = x64 ] || [ "$architecture" = universal ]; } &&
   { [ -z "$dart_x64" ] || [ ! -x "$dart_x64" ]; }; then
  echo 'An x64 Dart SDK is required. Set LC_DART_X64 or pass --dart-x64.' >&2
  exit 1
fi

if [ "$skip_flutter_build" = false ]; then
  flutter pub get --enforce-lockfile
  flutter build macos --release --build-name "$version"
fi

application="$repository_root/build/macos/Build/Products/Release/lc.app"
if [ ! -d "$application" ]; then
  echo "macOS release application was not found at $application" >&2
  exit 1
fi
application_executable="$application/Contents/MacOS/lc"
if [ ! -x "$application_executable" ]; then
  echo 'The macOS application executable is missing.' >&2
  exit 1
fi
case "$architecture" in
  arm64)
    application_architectures='arm64'
    distribution_architectures='arm64'
    ;;
  x64)
    application_architectures='x86_64'
    distribution_architectures='x86_64'
    ;;
  universal)
    application_architectures='arm64 x86_64'
    distribution_architectures='arm64,x86_64'
    ;;
esac
# shellcheck disable=SC2086
if ! /usr/bin/lipo "$application_executable" -verify_arch $application_architectures; then
  echo "The macOS application does not support $architecture." >&2
  exit 1
fi

staging="$repository_root/build/packaging/macos"
payload="$staging/payload"
package_scripts="$staging/package-scripts"
cli_staging="$staging/cli"
/bin/rm -rf "$staging"
/bin/mkdir -p \
  "$payload/Applications" \
  "$payload/Library/Application Support/DevEnvironmentManager/bin" \
  "$package_scripts" \
  "$cli_staging" \
  "$output_directory"

installed_cli="$payload/Library/Application Support/DevEnvironmentManager/bin/lc"
if [ "$architecture" = arm64 ] || [ "$architecture" = universal ]; then
  "$dart_arm64" compile exe --target-os macos --target-arch arm64 \
    --output "$cli_staging/lc-arm64" bin/lc.dart
fi
if [ "$architecture" = x64 ] || [ "$architecture" = universal ]; then
  "$dart_x64" compile exe --target-os macos --target-arch x64 \
    --output "$cli_staging/lc-x64" bin/lc.dart
fi
case "$architecture" in
  arm64)
    /bin/cp "$cli_staging/lc-arm64" "$installed_cli"
    cli_architectures='arm64'
    ;;
  x64)
    /bin/cp "$cli_staging/lc-x64" "$installed_cli"
    cli_architectures='x86_64'
    ;;
  universal)
    /usr/bin/lipo -create \
      "$cli_staging/lc-arm64" \
      "$cli_staging/lc-x64" \
      -output "$installed_cli"
    cli_architectures='arm64 x86_64'
    ;;
esac
# shellcheck disable=SC2086
/usr/bin/lipo "$installed_cli" -verify_arch $cli_architectures
if [ "$architecture" = "$native_architecture" ] ||
   [ "$architecture" = universal ]; then
  "$installed_cli" --version >/dev/null
fi

/usr/bin/ditto "$application" "$payload/Applications/lc.app"
/bin/cp packaging/macos/lc-uninstall \
  "$payload/Library/Application Support/DevEnvironmentManager/bin/lc-uninstall"
/bin/cp packaging/macos/scripts/postinstall "$package_scripts/postinstall"
/bin/chmod 755 \
  "$payload/Library/Application Support/DevEnvironmentManager/bin/lc" \
  "$payload/Library/Application Support/DevEnvironmentManager/bin/lc-uninstall" \
  "$package_scripts/postinstall"

component_package="$staging/lc-component.pkg"
/usr/bin/pkgbuild \
  --root "$payload" \
  --install-location / \
  --scripts "$package_scripts" \
  --identifier com.cacube.lc.user \
  --version "$version" \
  "$component_package"

distribution="$staging/Distribution.xml"
/usr/bin/sed "s/__LC_VERSION__/$version/g" \
  packaging/macos/Distribution.xml |
  /usr/bin/sed "s/__LC_HOST_ARCHITECTURES__/$distribution_architectures/g" \
    > "$distribution"
/usr/bin/xmllint --noout "$distribution"

installer="$output_directory/lc-macos-$architecture.pkg"
/bin/rm -f "$installer"
/usr/bin/productbuild \
  --distribution "$distribution" \
  --package-path "$staging" \
  "$installer"

/usr/bin/xcrun installer -pkg "$installer" -dominfo
echo "Built $installer"
