#!/bin/sh
# Lumen installer. Downloads a self-contained release for your platform and
# installs it under ~/.lumen. No separate toolchain needed.
#
#   curl -fsSL https://raw.githubusercontent.com/labidiaymen/ljs/main/install.sh | sh
set -e

REPO="labidiaymen/ljs"
LUMEN_HOME="${LUMEN_HOME:-$HOME/.lumen}"

os=$(uname -s)
arch=$(uname -m)
case "$os" in
  Linux) os=linux ;;
  Darwin) os=macos ;;
  *) echo "unsupported OS: $os (Windows: download the .zip from the releases page)"; exit 1 ;;
esac
case "$arch" in
  x86_64|amd64) arch=x86_64 ;;
  arm64|aarch64) arch=aarch64 ;;
  *) echo "unsupported architecture: $arch"; exit 1 ;;
esac

target="${arch}-${os}"
asset="lumen-${target}.tar.gz"
url="https://github.com/${REPO}/releases/latest/download/${asset}"

echo "Installing Lumen (${target}) ..."
tmp=$(mktemp -d)
curl -fSL "$url" -o "$tmp/$asset"

rm -rf "$LUMEN_HOME"
mkdir -p "$LUMEN_HOME"
tar -xzf "$tmp/$asset" -C "$tmp"
mv "$tmp/lumen-${target}"/* "$LUMEN_HOME/"
rm -rf "$tmp"

# Launcher: makes the bundled backend reachable to `lumen` only — it is not
# added to your interactive shell PATH.
mkdir -p "$LUMEN_HOME/bin"
cat > "$LUMEN_HOME/bin/lumen" <<EOF
#!/bin/sh
PATH="$LUMEN_HOME/zig:\$PATH" exec "$LUMEN_HOME/lumen" "\$@"
EOF
chmod +x "$LUMEN_HOME/bin/lumen"

echo ""
echo "Lumen installed to $LUMEN_HOME"
echo "Add it to your PATH (then restart your shell):"
echo "  export PATH=\"$LUMEN_HOME/bin:\$PATH\""
echo ""
echo "Then try:  lumen compile hello.ts && ./hello"
