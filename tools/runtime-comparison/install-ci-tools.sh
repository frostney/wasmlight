#!/usr/bin/env bash

set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: install-ci-tools.sh <tool-root>" >&2
  exit 2
fi

tool_root=$1
marker="$tool_root/.wasmlight-runtime-tools-v1"
if [ -f "$marker" ]; then
  echo "runtime comparison tools already prepared at $tool_root"
  exit 0
fi

case "$(uname -s)-$(uname -m)" in
  Linux-x86_64) ;;
  *)
    echo "runtime comparison CI tools support Linux x86-64 only" >&2
    exit 1
    ;;
esac

mkdir -p "$tool_root/bin" "$tool_root/packages"
download_dir=$(mktemp -d)
trap 'rm -rf "$download_dir"' EXIT

fetch() {
  local name=$1
  local url=$2
  local sha256=$3
  local output="$download_dir/$name"
  curl --fail --location --retry 3 --silent --show-error "$url" -o "$output"
  printf '%s  %s\n' "$sha256" "$output" | sha256sum --check --status
  printf '%s\n' "$output"
}

unpack_gz() {
  local package=$1
  local archive=$2
  mkdir -p "$tool_root/packages/$package"
  tar -xzf "$archive" -C "$tool_root/packages/$package"
}

unpack_xz() {
  local package=$1
  local archive=$2
  mkdir -p "$tool_root/packages/$package"
  tar -xJf "$archive" -C "$tool_root/packages/$package"
}

link_binary() {
  local package=$1
  local name=$2
  local executable
  executable=$(find "$tool_root/packages/$package" -type f -name "$name" -perm -u+x -print -quit)
  if [ -z "$executable" ]; then
    echo "could not find $name in $package" >&2
    exit 1
  fi
  ln -sfn "$executable" "$tool_root/bin/$name"
}

write_wrapper() {
  local package=$1
  local name=$2
  local executable
  executable=$(find "$tool_root/packages/$package" -type f -name "$name" -perm -u+x -print -quit)
  if [ -z "$executable" ]; then
    echo "could not find $name in $package" >&2
    exit 1
  fi
  {
    echo '#!/usr/bin/env bash'
    echo 'set -euo pipefail'
    printf 'export LD_LIBRARY_PATH=%q' "$tool_root/packages/$package/lib"
    printf '%s\n' "\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
    printf 'exec %q "$@"\n' "$executable"
  } > "$tool_root/bin/$name"
  chmod +x "$tool_root/bin/$name"
}

archive=$(fetch wasmtime.tar.xz \
  https://github.com/bytecodealliance/wasmtime/releases/download/v47.0.3/wasmtime-v47.0.3-x86_64-linux.tar.xz \
  ca1fc56d1afc40c8782e96c297fd182a0da162f9a8f52a1e7b094e1dd648e178)
unpack_xz wasmtime "$archive"
link_binary wasmtime wasmtime

archive=$(fetch wasmer.tar.gz \
  https://github.com/wasmerio/wasmer/releases/download/v7.2.1/wasmer-linux-amd64.tar.gz \
  c46d6ff34a12b40d2e57bfc2ccbb8b9e209b0987ab305233619798b264a6bae5)
unpack_gz wasmer "$archive"
write_wrapper wasmer wasmer

archive=$(fetch wasmedge.tar.gz \
  https://github.com/WasmEdge/WasmEdge/releases/download/0.17.1/WasmEdge-0.17.1-manylinux_2_28_x86_64.tar.gz \
  27a1abec072ddf45b40e2e81e33c1e5fe9b241f31fd1bbf0182f05097489a07a)
unpack_gz wasmedge "$archive"
write_wrapper wasmedge wasmedge

archive=$(fetch iwasm.tar.gz \
  https://github.com/wasm-micro-runtime/wasm-micro-runtime/releases/download/WAMR-2.4.5/iwasm-2.4.5-x86_64-ubuntu-22.04.tar.gz \
  61e9d4c77e8f7b06d5cea657b2c319b9be5d51ec51ad8f6f576af84cecd391a3)
unpack_gz wamr "$archive"
link_binary wamr iwasm

archive=$(fetch wamrc.tar.gz \
  https://github.com/wasm-micro-runtime/wasm-micro-runtime/releases/download/WAMR-2.4.5/wamrc-2.4.5-x86_64-ubuntu-22.04.tar.gz \
  fedda99950a70f7dc45470ce88e12bf9e435b9482058ae97ce2cadd760e2329f)
unpack_gz wamrc "$archive"
link_binary wamrc wamrc

archive=$(fetch wazero.tar.gz \
  https://github.com/wazero/wazero/releases/download/v1.12.0/wazero_1.12.0_linux_amd64.tar.gz \
  88019896950340e8839b94af0510b248c3400d8d8f4a9b335dcaad93ac0484ff)
unpack_gz wazero "$archive"
link_binary wazero wazero

command -v cmake >/dev/null
command -v cc >/dev/null
archive=$(fetch wasm3-source.tar.gz \
  https://codeload.github.com/wasm3/wasm3/tar.gz/6b8bcb1e07bf26ebef09a7211b0a37a446eafd52 \
  d3d7a1cabbdc534e83c24be5181c637b03968f60a97fe0aac6cb515ee803b229)
unpack_gz wasm3 "$archive"
wasm3_source=$(find "$tool_root/packages/wasm3" -mindepth 1 -maxdepth 1 \
  -type d -name 'wasm3-*' -print -quit)
if [ -z "$wasm3_source" ] || [ ! -f "$wasm3_source/CMakeLists.txt" ]; then
  echo "could not find the wasm3 source root" >&2
  exit 1
fi
cmake -S "$wasm3_source" -B "$tool_root/packages/wasm3-build" \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_NATIVE=OFF \
  -DBUILD_WASI=simple
cmake --build "$tool_root/packages/wasm3-build" --parallel 2
install -m 755 "$tool_root/packages/wasm3-build/wasm3" \
  "$tool_root/packages/wasm3/wasm3"
ln -sfn "$tool_root/packages/wasm3/wasm3" "$tool_root/bin/wasm3"

archive=$(fetch wasm-tools.tar.gz \
  https://github.com/bytecodealliance/wasm-tools/releases/download/v1.256.0/wasm-tools-1.256.0-x86_64-linux.tar.gz \
  0b488be25c9e8a74dfa09f7eac614a927ea197f389d8fa5a21ffb1c15deb469d)
unpack_gz wasm-tools "$archive"
link_binary wasm-tools wasm-tools

archive=$(fetch wabt.tar.gz \
  https://github.com/WebAssembly/wabt/releases/download/1.0.41/wabt-1.0.41-linux-x64.tar.gz \
  83f8122e924745fcd70636e3594bc01c4c47f2d4c8f3c63b5d70d3f83a482677)
unpack_gz wabt "$archive"
link_binary wabt wat2wasm

touch "$marker"
echo "runtime comparison tools prepared at $tool_root"
