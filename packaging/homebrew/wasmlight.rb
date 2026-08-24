# Draft Homebrew formula for frostney/homebrew-tap.
#
# This file is not live. Do not copy it into frostney/homebrew-tap until
# /create-release has published 0.2.0 archives and
# wasmlight-0.2.0-checksums.txt. The sha256 values below are the draft
# sentinel (64 zeros). Replace each from that checksums file.
#
# Pattern matches Formula/lwpt.rb and Formula/gocciascript.rb in the tap:
# per-OS/arch url + sha256, then bin.install of the compiler. The 0.2.0
# archive also carries share/wasmlight/shells, which this formula stages
# into pkgshare.
#
# Official checksum rule: https://docs.brew.sh/Checksum-Requirements

class Wasmlight < Formula
  desc "WebAssembly runtime and native compiler for Object Pascal"
  homepage "https://github.com/frostney/wasmlight"
  license "MIT"
  version "0.2.0"

  DRAFT_SHA256 = "0000000000000000000000000000000000000000000000000000000000000000"

  on_macos do
    on_arm do
      url "https://github.com/frostney/wasmlight/releases/download/0.2.0/wasmlight-0.2.0-macos-arm64.tar.gz"
      sha256 DRAFT_SHA256
    end

    on_intel do
      url "https://github.com/frostney/wasmlight/releases/download/0.2.0/wasmlight-0.2.0-macos-x64.tar.gz"
      sha256 DRAFT_SHA256
    end
  end

  on_linux do
    on_arm do
      url "https://github.com/frostney/wasmlight/releases/download/0.2.0/wasmlight-0.2.0-linux-arm64.tar.gz"
      sha256 DRAFT_SHA256
    end

    on_intel do
      url "https://github.com/frostney/wasmlight/releases/download/0.2.0/wasmlight-0.2.0-linux-x64.tar.gz"
      sha256 DRAFT_SHA256
    end
  end

  def install
    chmod 0755, "wasmlight"
    bin.install "wasmlight"
    shells = Pathname("share/wasmlight/shells")
    (pkgshare/"shells").install Dir[shells/"*"] if shells.directory?
  end

  test do
    assert_match "wasmlight #{version}", shell_output("#{bin}/wasmlight --version")
    assert_predicate pkgshare/"shells", :exist?
  end
end
