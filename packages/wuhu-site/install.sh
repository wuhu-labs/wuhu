#!/bin/sh
# wuhu installer — https://wuhu.ai
# usage: curl -fsSL https://wuhu.ai/install.sh | sh
#   WUHU_LANE=dev       the dev lane's latest instead of beta
#   WUHU_VERSION=x.y.z  that exact version
set -eu

BASE="${WUHU_BASE_URL:-https://wuhu.ai}"
LANE="${WUHU_LANE:-beta}"

fail() { echo "wuhu: $*" >&2; exit 1; }

os="$(uname -s)"
arch="$(uname -m)"
case "$os/$arch" in
  Darwin/arm64)        platform="macos-arm64"; ext="zip" ;;
  Linux/x86_64)        platform="linux-amd64"; ext="tar.gz" ;;
  *) fail "no build for $os/$arch (have: macOS arm64, Linux x86_64)" ;;
esac

bin="$HOME/.wuhu/bin"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp" "$bin/.wuhu-$$" "$bin/.wuhu-current-$$"' EXIT

# The lane pointer is JSON the release pipeline writes; none of its values hold
# whitespace, so with whitespace stripped sed can pick fields out of it.
field() { sed -n "s/.*\"$1\":\"\([^\"]*\)\".*/\1/p"; }

check_version() {
  case "$1" in
    *[!0-9A-Za-z.-]*|"") fail "invalid version: $1" ;;
  esac
}

if [ -n "${WUHU_VERSION:-}" ]; then
  VERSION="$WUHU_VERSION"
  check_version "$VERSION"
  artifact="wuhu-$VERSION-$platform.$ext"
  url="$BASE/releases/$artifact"
  curl -fsSL "$url.sha256" -o "$tmp/sha256" \
    || fail "no $platform build of $VERSION at $url"
  sha256="$(cut -d' ' -f1 "$tmp/sha256")"
else
  case "$LANE" in
    *[!a-z]*|"") fail "invalid WUHU_LANE: $LANE" ;;
  esac
  curl -fsSL "$BASE/releases/$LANE/latest.json" -o "$tmp/latest.json" \
    || fail "no $LANE lane at $BASE/releases/$LANE/latest.json"
  pointer="$(tr -d ' \t\r\n' < "$tmp/latest.json")"
  VERSION="$(printf '%s' "$pointer" | field version)"
  check_version "$VERSION"
  entry="$(printf '%s' "$pointer" | sed -n "s/.*\"$platform\":{\([^}]*\)}.*/\1/p")"
  artifact="$(printf '%s' "$entry" | field name)"
  url="$(printf '%s' "$entry" | field url)"
  sha256="$(printf '%s' "$entry" | field sha256)"
  [ -n "$artifact" ] && [ -n "$url" ] || fail "the $LANE lane has no $platform build"
fi

case "$sha256" in
  *[!0-9a-f]*|"") fail "no sha256 for $artifact" ;;
esac
[ "${#sha256}" -eq 64 ] || fail "no sha256 for $artifact"

dest="$bin/$VERSION"

echo "wuhu $VERSION ($os/$arch)"
echo "  fetch   $url"
curl -fSL --progress-bar "$url" -o "$tmp/$artifact"

echo "  verify  sha256"
if command -v shasum >/dev/null; then
  actual="$(shasum -a 256 "$tmp/$artifact" | cut -d' ' -f1)"
else
  actual="$(sha256sum "$tmp/$artifact" | cut -d' ' -f1)"
fi
[ "$actual" = "$sha256" ] || fail "checksum mismatch for $artifact, aborting"

mkdir -p "$dest"
case "$artifact" in
  *.zip)    unzip -oq "$tmp/$artifact" -d "$dest" ;;
  *.tar.gz) tar -xzf "$tmp/$artifact" -C "$dest" ;;
esac
chmod +x "$dest/wuhu"
# A real file at a fixed path, since macOS keys privacy grants by it; replaced by
# rename, never written into, since the kernel caches a signature per inode.
cp "$dest/wuhu" "$bin/.wuhu-$$"
chmod 755 "$bin/.wuhu-$$"
mv -f "$bin/.wuhu-$$" "$bin/wuhu"
echo "$VERSION" > "$bin/.wuhu-current-$$"
mv -f "$bin/.wuhu-current-$$" "$bin/.current"

echo "  install $bin/wuhu from $VERSION/wuhu"
"$bin/wuhu" --version

case ":$PATH:" in
  *":$HOME/.wuhu/bin:"*) ;;
  *)
    echo
    echo "add wuhu to your PATH:"
    echo '  fish:      fish_add_path ~/.wuhu/bin'
    echo '  bash/zsh:  echo '\''export PATH="$HOME/.wuhu/bin:$PATH"'\'' >> ~/.profile'
    ;;
esac
echo
echo "wuhu! next: wuhu use <your-space-host:port>"
