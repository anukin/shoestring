#!/usr/bin/env python3
"""Seal an existing native release into local artifacts. Never uploads or overwrites."""
import argparse
import gzip
import hashlib
import json
import pathlib
import tarfile


def package(source, destination, allow_dirty=False):
    if not __debug__:
        raise RuntimeError("Packaging requires Python assertions enabled")
    source = source.resolve(strict=True)
    manifest = json.loads((source / "manifest.json").read_text())
    assert manifest["format"] == "shoestring-release" and manifest["version"] == 1
    assert manifest["target"] == "aarch64-apple-darwin"
    assert allow_dirty or manifest["source_dirty"] is False, "Commit the source before packaging for publication"
    version = manifest["application_version"]
    assert version and all(c in "0123456789." for c in version)
    assert (source / "releases/COOKIE").read_text().strip() == "shoestring_distribution_disabled"
    helper = source / f"lib/shoestring-{version}/priv/bin/shoestring-terminal"
    assert hashlib.sha256(helper.read_bytes()).hexdigest() == manifest["helper_sha256"]
    assert (source / "bin/shoestringctl").is_file()
    entries = sorted(source.rglob("*"))
    for path in entries:
        assert path.resolve().is_relative_to(source), "External release symlink refused"
        assert path.is_file() or path.is_dir() or path.is_symlink(), "Special file refused"
    expected = manifest["files_sha256"]
    actual = {str(path.relative_to(source)): hashlib.sha256(path.read_bytes()).hexdigest()
              for path in entries if path.is_file() and path != source / "manifest.json"}
    assert actual == expected, "Release files changed after assembly; use a fresh build"
    destination.mkdir(parents=True, exist_ok=False)
    name = f"shoestring-{version}-aarch64-apple-darwin.tar.gz"
    archive = destination / name
    with archive.open("xb") as raw, gzip.GzipFile(fileobj=raw, mode="wb", filename="", mtime=0) as zipped:
        with tarfile.open(fileobj=zipped, mode="w") as tar:
            for path in entries:
                info = tar.gettarinfo(str(path), arcname=str(path.relative_to(source)))
                info.uid = info.gid = info.mtime = 0
                info.uname = info.gname = ""
                if info.isfile():
                    with path.open("rb") as file:
                        tar.addfile(info, file)
                else:
                    tar.addfile(info)
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    (destination / "SHA256SUMS").write_text(f"{digest}  {name}\n")
    formula = f'''class Shoestring < Formula
  desc "Local supervised coding work with explicit capacity and verification"
  homepage "https://github.com/anukin/shoestring"
  url "https://github.com/anukin/shoestring/releases/download/v{version}/{name}"
  version "{version}"
  sha256 "{digest}"
  license "MIT"
  depends_on :macos
  depends_on arch: :arm64
  depends_on "openssl@3"
  depends_on "git"
  depends_on "python@3.14"

  def install
    libexec.install Dir["*"]
    (bin/"shoestring").write <<~SH
      #!/bin/sh
      export PATH="#{{Formula["python@3.14"].opt_libexec}}/bin:$PATH"
      exec "#{{libexec}}/bin/shoestringctl" "$@"
    SH
    chmod 0755, bin/"shoestring"
  end

  test do
    assert_match "{version}", shell_output("#{{bin}}/shoestring version")
  end
end
'''
    (destination / "shoestring.rb").write_text(formula)
    print(json.dumps({"archive": name, "sha256": digest, "published": False}, sort_keys=True))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=pathlib.Path)
    parser.add_argument("destination", type=pathlib.Path)
    parser.add_argument("--allow-dirty", action="store_true", help="Local candidate verification only; not publishable")
    args = parser.parse_args()
    package(args.source, args.destination, args.allow_dirty)
