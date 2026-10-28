# Bundled dependencies

`slaxml.lua` is SLAXML 0.8 by Gavin Kistner, copied without changes from [Phrogz/SLAXML](https://github.com/Phrogz/SLAXML) at commit `756ffad03d2a06271170a0ba82d6eac02cc2a5ca`. Its MIT license is retained in `SLAXML-LICENSE.txt`. It provides namespace-aware XML tokenization for generated SVG. The plugin wrapper adds balanced-element checks and a passive SVG allowlist; no system Lua package or Python XML parser is required.

`libyaml.lua` contains LuaJIT FFI declarations derived from the libyaml 0.2 public `yaml.h` ABI (parser, event, marks, and supporting types). It loads the system shared library in process rather than bundling a binary or invoking Python. The upstream MIT license is retained in `LIBYAML-LICENSE.txt`. `yaml.lua` owns value construction, diagnostics, and block-preserving writes; the native library owns syntax/tokenization. No compiler, development headers, or Lua package installation is required at runtime.
