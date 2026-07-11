# campfire.nvim

Neovim-only Clojure nREPL client with a Lua core and Campfire command surface.

## Install

Install as a normal Neovim plugin with your plugin manager, then call:

```lua
require('campfire').setup()
```

## Quickstart

```vim
:Connect nrepl://localhost:7888
:Eval (+ 1 2)
:Doc map
:RunTests
```

First eval/doc/completion/test action auto-connects when Campfire finds a
project port file: `.nrepl-port`, `repl-port`, `target/repl-port`, or
`.shadow-cljs/nrepl.port`. Unix sockets are supported with
`nrepl+unix:///path/to/socket`, and HTTP (drawbridge) endpoints with
`:Connect https://user:pass@host/repl` (credentials, if any, do HTTP basic auth).

## Connect grammar

```
:Connect [URL] [<template>] [key=value]... [+form]
```

Bare invocation walks up for a port file (`.nrepl-port`,
`.shadow-cljs/nrepl.port`) and connects to it. With a URL or port,
connects directly and auto-detects the runtime.

```vim
:Connect                                       " discover port
:Connect 7888                                  " explicit port
:Connect <shadow:app>                          " template bootstrap
```

Labels become useful when running several connections that share a
runtime — e.g. multiple shadow-cljs builds against one JVM:

```vim
:Connect 7888 <shadow:frontend> label=ui
:Connect 7888 <shadow:worker> label=worker
:Connect 7888 +(shadow.cljs.devtools.api/repl :test) label=test
```

Then `:Disconnect ui`, `:Scope worker`, and the
`:Connections` list stay readable.

### Flags

| Flag | Purpose |
| --- | --- |
| `label=<name>` | Optional nickname. Used by `:Disconnect` and friends. |
| `path=<dir>` | Project path. Defaults to the nearest ancestor containing `deps.edn`, `project.clj`, `shadow-cljs.edn`, `bb.edn`, `.nrepl-port`, or `.shadow-cljs/nrepl.port`. |
| `lang=<runtime>` | Force runtime. Skips auto-detection. |

### Templates

| Template | Bootstrap |
| --- | --- |
| `<node>` | piggieback + `cljs.repl.node` |
| `<browser>` | piggieback + `cljs.repl.browser` |
| `<nbb>` | native nbb (no bootstrap) |
| `<figwheel>` | figwheel-sidecar |
| `<figwheel-main:BUILD>` | figwheel.main with named build |
| `<shadow:BUILD>` | shadow-cljs with named build |

### Ad-hoc bootstrap

`+form` is always last. Everything after `+` is the bootstrap form,
unescaped. Use it when no template fits:

```vim
:Connect 7888 +(my.custom/repl :opts)
```

### Connections

```vim
:Connections          " list all
:Scope ops            " pin current buffer to connection labelled ops
:Scope!               " clear pin
:Disconnect ops       " close by label
:Reconnect ops        " reconnect with same params
```

Routing without a pin uses the file extension: `.clj` → `lang=clj`
connection, `.cljs` → `lang=cljs`, `.bb` → `lang=bb`. `.cljc` defaults
to `clj`. `:Scope` is the usual way to override `.cljc`; for
other extensions it picks a non-default connection when several share
the same runtime.

## none-ls

Register Campfire sources when setting up none-ls:

```lua
local null_ls = require('null-ls')

local sources = {
  null_ls.builtins.completion.spell,
}
vim.list_extend(sources, require('campfire.none_ls').sources())

null_ls.setup({ sources = sources })
```

## Health

Run `:checkhealth campfire`.

## Tests

Install mini.nvim's `mini.test`, then run:

```sh
./test
```
