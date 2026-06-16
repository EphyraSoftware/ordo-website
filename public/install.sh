#!/bin/sh
# Ordo installer for Linux and macOS.
#
#   curl -fsSL https://getordo.dev/install.sh | sh
#
# Downloads a prebuilt binary from https://dl.getordo.dev, verifies its SHA-256
# checksum (always) and its minisign signature (when minisign is installed),
# and installs it.
#
# Environment overrides:
#   ORDO_BIN          binary to install: ordo (default), ordo-agent, ordo-orchestrator
#   ORDO_VERSION      latest (default) or a tag like v0.0.5
#   ORDO_INSTALL_DIR  install directory (default /usr/local/bin)
set -eu

BASE_URL="https://dl.getordo.dev"
# Pinned Ordo minisign public key (see https://getordo.dev/minisign.pub).
PUBKEY="RWRd9zVINZTXqb/dImYYNVWuPwjPSzRTcKaKnd7yZw7Iltt+tEArKFtv"

BIN="${ORDO_BIN:-ordo}"
VERSION="${ORDO_VERSION:-latest}"
INSTALL_DIR="${ORDO_INSTALL_DIR:-/usr/local/bin}"

err() {
	echo "install.sh: $*" >&2
	exit 1
}

need() {
	command -v "$1" >/dev/null 2>&1 || err "required command not found: $1"
}

need curl
need tar

# Resolve the target triple from the host OS and architecture.
os="$(uname -s)"
arch="$(uname -m)"
case "$os" in
Linux)
	case "$arch" in
	x86_64 | amd64) target="x86_64-unknown-linux-musl" ;;
	aarch64 | arm64) target="aarch64-unknown-linux-musl" ;;
	*) err "unsupported architecture: $arch" ;;
	esac
	;;
Darwin)
	case "$arch" in
	x86_64) target="x86_64-apple-darwin" ;;
	arm64) target="aarch64-apple-darwin" ;;
	*) err "unsupported architecture: $arch" ;;
	esac
	;;
*) err "unsupported operating system: $os" ;;
esac

if [ "$VERSION" = "latest" ]; then
	prefix="$BASE_URL/latest"
else
	prefix="$BASE_URL/$VERSION"
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# The checksum file lists every asset for the release; use it to discover the
# exact (version-stamped) filename for this binary and target, and to verify it.
curl -fsSL "$prefix/SHA256SUMS" -o "$tmp/SHA256SUMS" ||
	err "could not fetch $prefix/SHA256SUMS"
curl -fsSL "$prefix/SHA256SUMS.minisig" -o "$tmp/SHA256SUMS.minisig" 2>/dev/null || true

# Match "<bin>-v<version>-<target>.tar.gz" without matching a different binary
# whose name shares the prefix (e.g. ordo vs ordo-agent).
asset="$(awk -v p="^${BIN}-v[0-9].*-${target}[.]tar[.]gz$" '$2 ~ p { print $2 }' "$tmp/SHA256SUMS" | head -n1)"
[ -n "$asset" ] || err "no ${BIN} build for ${target} in ${prefix}"

# Verify the checksum file's signature when minisign is available; this is the
# only check that detects a tampered host, so warn clearly when it is skipped.
if command -v minisign >/dev/null 2>&1 && [ -s "$tmp/SHA256SUMS.minisig" ]; then
	printf 'untrusted comment: ordo minisign public key\n%s\n' "$PUBKEY" >"$tmp/ordo.pub"
	minisign -Vm "$tmp/SHA256SUMS" -p "$tmp/ordo.pub" >/dev/null ||
		err "minisign signature verification failed for SHA256SUMS"
	echo "minisign signature verified"
else
	echo "note: minisign not installed; skipping signature check (checksum still verified)" >&2
fi

curl -fsSL "$prefix/$asset" -o "$tmp/$asset" || err "could not download $prefix/$asset"

# Verify the downloaded archive against its line in SHA256SUMS.
expected="$(awk -v a="$asset" '$2 == a { print $1 }' "$tmp/SHA256SUMS")"
if command -v sha256sum >/dev/null 2>&1; then
	echo "$expected  $tmp/$asset" | sha256sum -c - >/dev/null || err "checksum mismatch for $asset"
elif command -v shasum >/dev/null 2>&1; then
	echo "$expected  $tmp/$asset" | shasum -a 256 -c - >/dev/null || err "checksum mismatch for $asset"
else
	err "no sha256 tool found (need sha256sum or shasum)"
fi
echo "checksum verified"

tar -xzf "$tmp/$asset" -C "$tmp" || err "could not extract $asset"
[ -f "$tmp/$BIN" ] || err "archive did not contain expected binary: $BIN"

if [ -w "$INSTALL_DIR" ]; then
	install -m 0755 "$tmp/$BIN" "$INSTALL_DIR/$BIN"
elif command -v sudo >/dev/null 2>&1; then
	echo "installing to $INSTALL_DIR (requires sudo)"
	sudo install -m 0755 "$tmp/$BIN" "$INSTALL_DIR/$BIN"
else
	err "$INSTALL_DIR is not writable and sudo is not available; set ORDO_INSTALL_DIR"
fi

echo "installed $BIN to $INSTALL_DIR/$BIN"
