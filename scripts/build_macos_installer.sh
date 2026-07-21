#!/bin/bash
set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
repository_root=$(cd "$script_dir/.." && pwd)
cd "$repository_root"

version=''
output_directory="$repository_root/build/installers"
skip_flutter_build=false
architecture=native

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
  -h, --help           Show this help.
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
/bin/rm -rf "$staging"
/bin/mkdir -p \
  "$payload/Applications" \
  "$package_scripts" \
  "$output_directory"

/usr/bin/ditto "$application" "$payload/Applications/lc.app"
/bin/cp packaging/macos/scripts/postinstall "$package_scripts/postinstall"
/bin/chmod 755 "$package_scripts/postinstall"

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
