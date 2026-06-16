#!/bin/sh
# Ordo installer for Linux and macOS.
#
# With no argument it installs the operator/client tools (ordo and ordo-state).
# Pass a component to install just that one:
#   ordo / ordo-state   operator/client     curl -fsSL https://getordo.dev/install.sh | sh
#   ordo-orchestrator   orchestrator host   curl -fsSL https://getordo.dev/install.sh | sh -s -- ordo-orchestrator
#   ordo-agent          a managed machine   curl -fsSL https://getordo.dev/install.sh | sh -s -- ordo-agent
#
# Downloads prebuilt binaries from https://dl.getordo.dev, verifies their SHA-256
# checksums (always) and the minisign signature (when minisign is installed),
# and installs them. A single component may also be set with ORDO_BIN.
#
# Environment overrides:
#   ORDO_BIN          component to install (alternative to the positional argument)
#   ORDO_VERSION      latest (default) or a tag like v0.0.6
#   ORDO_INSTALL_DIR  install directory (default /usr/local/bin)
set -eu

BASE_URL="https://dl.getordo.dev"
# Pinned Ordo minisign public key (see https://getordo.dev/minisign.pub).
PUBKEY="RWRd9zVINZTXqb/dImYYNVWuPwjPSzRTcKaKnd7yZw7Iltt+tEArKFtv"

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

# Components to install: an explicit argument or ORDO_BIN selects one; the
# default installs the operator/client tools.
if [ "$#" -ge 1 ]; then
	BINS="$1"
elif [ -n "${ORDO_BIN:-}" ]; then
	BINS="$ORDO_BIN"
else
	BINS="ordo ordo-state"
fi

for b in $BINS; do
	case "$b" in
	ordo | ordo-state | ordo-agent | ordo-orchestrator) ;;
	*) err "unknown component: $b (expected ordo, ordo-state, ordo-agent, or ordo-orchestrator)" ;;
	esac
done

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
# exact (version-stamped) filenames and to verify each download.
curl -fsSL "$prefix/SHA256SUMS" -o "$tmp/SHA256SUMS" ||
	err "could not fetch $prefix/SHA256SUMS"
curl -fsSL "$prefix/SHA256SUMS.minisig" -o "$tmp/SHA256SUMS.minisig" 2>/dev/null || true

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

verify_sha256() {
	# verify_sha256 <expected> <file>
	if command -v sha256sum >/dev/null 2>&1; then
		echo "$1  $2" | sha256sum -c - >/dev/null
	elif command -v shasum >/dev/null 2>&1; then
		echo "$1  $2" | shasum -a 256 -c - >/dev/null
	else
		err "no sha256 tool found (need sha256sum or shasum)"
	fi
}

install_one() {
	bin="$1"
	# Match "<bin>-v<version>-<target>.tar.gz" without matching a different
	# binary whose name shares the prefix (e.g. ordo vs ordo-state).
	asset="$(awk -v p="^${bin}-v[0-9].*-${target}[.]tar[.]gz$" '$2 ~ p { print $2 }' "$tmp/SHA256SUMS" | head -n1)"
	[ -n "$asset" ] || err "no ${bin} build for ${target} in ${prefix}"

	curl -fsSL "$prefix/$asset" -o "$tmp/$asset" || err "could not download $prefix/$asset"
	expected="$(awk -v a="$asset" '$2 == a { print $1 }' "$tmp/SHA256SUMS")"
	verify_sha256 "$expected" "$tmp/$asset" || err "checksum mismatch for $asset"

	tar -xzf "$tmp/$asset" -C "$tmp" || err "could not extract $asset"
	[ -f "$tmp/$bin" ] || err "archive did not contain expected binary: $bin"

	if [ -w "$INSTALL_DIR" ]; then
		install -m 0755 "$tmp/$bin" "$INSTALL_DIR/$bin"
	elif command -v sudo >/dev/null 2>&1; then
		sudo install -m 0755 "$tmp/$bin" "$INSTALL_DIR/$bin"
	else
		err "$INSTALL_DIR is not writable and sudo is not available; set ORDO_INSTALL_DIR"
	fi
	echo "installed $bin to $INSTALL_DIR/$bin"
}

for b in $BINS; do
	install_one "$b"
done
