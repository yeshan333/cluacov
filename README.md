# cluacov

[![CI](https://github.com/lunarmodules/cluacov/actions/workflows/test.yml/badge.svg)](./.github/workflows/test.yml) [![LuaRocks](https://img.shields.io/luarocks/v/lunarmodules/cluacov?label=LuaRocks&color=2c3e67)](https://luarocks.org/modules/lunarmodules/cluacov)

C extensions for [LuaCov](https://github.com/lunarmodules/luacov), improving
performance and reducing number of lines incorrectly marked as missed.

To install using [LuaRocks](https://luarocks.org/) run
`luarocks install cluacov`. cluacov depends on luacov, so that running this
command is enough to set up luacov with extensions.

`cluacov.deepbranches` is an experimental helper for static branch-site
discovery. It currently reports branch sites for standard Lua bytecode and is
intended as a building block for future branch coverage support.
