// Learn more about moon.mod configuration:
// https://docs.moonbitlang.com/en/latest/toolchain/moon/module.html
//
// To add a dependency, run this command in your terminal:
//   moon add moonbitlang/x
//
// Or manually declare it in `import`, for example:
// import {
//   "moonbitlang/x@0.4.6",
// }

name = "unmbt/moon-taze"

version = "0.1.1"

readme = "README.md"

repository = "https://github.com/unmbt/moon-taze"

license = "MIT"

keywords = [ "cli", "dependency", "moonbit", "mooncakes" ]

preferred_target = "native"

description = "A reliable interactive dependency update tool for MoonBit projects."

import {
  "moonbitlang/async@0.21.3",
  "mizchi/tui@0.10.2",
}
