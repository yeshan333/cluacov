# cluacov

[![CI](https://github.com/lunarmodules/cluacov/actions/workflows/test.yml/badge.svg)](./.github/workflows/test.yml) [![LuaRocks](https://img.shields.io/luarocks/v/lunarmodules/cluacov?label=LuaRocks&color=2c3e67)](https://luarocks.org/modules/lunarmodules/cluacov)

C extensions for [LuaCov](https://github.com/lunarmodules/luacov), improving
performance and reducing number of lines incorrectly marked as missed.

To install using [LuaRocks](https://luarocks.org/) run
`luarocks install cluacov`. cluacov depends on luacov, so that running this
command is enough to set up luacov with extensions.

`cluacov.deepbranches` analyzes Lua bytecode to discover branch sites within
functions. It reports conditional branches (`if`/`elseif`/`and`/`or`), numeric
`for` loops, and generic `for` iterators. Combined with LuaCov line-hit data,
it enables branch coverage analysis with LCOV/HTML report generation.

See [docs/branch-coverage.md](docs/branch-coverage.md) for a detailed guide
on how branch coverage works, the API reference, and how to generate reports.
