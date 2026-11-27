// Learn more about moon.mod configuration:
// https://docs.moonbitlang.com/en/latest/toolchain/moon/module.html

name = "unmbt/moon-taze"

version = "0.1.2"

readme = "README.mbt.md"

repository = "https://github.com/unmbt/moon-taze"

license = "MIT"

keywords = [ "cli", "dependency", "moonbit", "mooncakes", "github-actions" ]

preferred_target = "native"

description = "A reliable dependency update tool for MoonBit projects and GitHub Actions."

import {
  "unmbt/moon-manifest@0.3.0",
  "unmbt/cac@0.1.1",
  "unmbt/clack@0.1.2",
}
