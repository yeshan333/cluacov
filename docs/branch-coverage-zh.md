# 分支覆盖率：`cluacov.deepbranches`

## 概述

`cluacov.deepbranches` 通过静态分析 Lua 函数的字节码来发现**分支站点** ——
程序执行可能走向两条路径的位置。将这些分支站点与
[LuaCov](https://github.com/lunarmodules/luacov) 的行命中数据交叉比对，
就可以计算分支覆盖率，并生成带有分支记录（`BRDA`）的 LCOV 报告。

## 支持的分支类型

| 类型 | 源码结构 | 说明 |
|------|---------|------|
| `test` | `if`、`elseif`、`and`、`or`、比较运算 | 条件判断后跳转 |
| `loop` | `for i = a, b`（循环回边） | 数值 for 循环的继续/退出判断 |
| `loop-entry` | `for i = a, b`（入口，Lua >= 5.4） | 数值 for 循环的初始入口判断 |
| `iterator` | `for k, v in f()` | 泛型 for 迭代器的耗尽判断 |

每个分支站点恰好有**两个目标**：两条可能的执行路径。

> **注意：** 目标按程序计数器（PC）升序排列，而非按语义方向排列。`targets[1]`
> 是 PC 较低的目标，不一定是"真分支路径"。这种排序方式稳定且满足覆盖率计算需求。

## API

```lua
local deepbranches = require("cluacov.deepbranches")

-- deepbranches.version : string（如 "1.0.0"）
-- deepbranches.get(func) -> 分支站点数组

local branches = deepbranches.get(some_function)
```

`get` 接受一个 **Lua 函数**（不能是 C 函数），返回分支站点数组。
会递归包含嵌套函数中的分支。

### 分支站点字段

| 字段 | 类型 | 说明 |
|------|------|------|
| `line` | number | 分支指令所在的源码行号 |
| `pc` | number | 分支指令的程序计数器（1-based） |
| `kind` | string | 分支类型：`"test"`、`"loop"`、`"loop-entry"` 或 `"iterator"` |
| `linedefined` | number | 所在函数的起始行号 |
| `targets` | table | 恰好包含 2 个目标的数组 |

### 目标字段

| 字段 | 类型 | 说明 |
|------|------|------|
| `line` | number | 目标指令所在的源码行号 |
| `pc` | number | 目标指令的程序计数器（1-based） |

### 示例

```lua
local deepbranches = require("cluacov.deepbranches")

local function example(x)
   if x > 0 then
      return "positive"
   else
      return "non-positive"
   end
end

local branches = deepbranches.get(example)
--[[
branches = {
   {
      line = 2,            -- "if x > 0"
      pc = 2,
      kind = "test",
      linedefined = 1,
      targets = {
         { line = 3, pc = 4 },   -- true  路径："return positive"
         { line = 5, pc = 6 },   -- false 路径："return non-positive"
      }
   }
}
]]
```

## 分支覆盖率计算原理

分支覆盖率衡量每个分支站点的**两条路径**是否都在测试中被执行过。

计算步骤：

1. 用 `deepbranches.get(func)` **发现**分支站点
2. 在 LuaCov 下**运行**代码，收集每行的命中次数
3. **过滤**分支（见下文"复合条件"）
4. **交叉比对**：检查每个可报告分支的目标行是否被命中

### 复合条件的处理

Lua 的**行级调试钩子**在每个源码行触发一次。当一行源码包含多个分支指令时
（如 `if a or b or c` 编译为 3 条 TEST 指令），它们共享相同的行命中计数——
仅凭行级钩子无法区分各条指令。

**过滤规则**：对于同一行有多个分支的情况，只报告**两个目标都在不同行**的分支。
只有这种分支的两个结果才能通过行命中数据真正区分。目标在本行的分支（中间的
短路跳转）被跳过。当同一行多个分支共享相同的目标行对时，只报告一个（去重）。

这种方式自然处理了以下场景：

- **`if a and b`** — 最后一个 TEST 的目标分别在 then 体和 else 体（都不在本行），
  因此被报告。第一个 TEST 有一个目标在本行（跳到下一个 TEST），因此被跳过。
- **`for i = 1, n`** — FORPREP 和 FORLOOP 是同一行的两个分支指令，但两者的
  目标都不在本行（循环体和循环后）。因为它们共享相同的目标行对，只报告一个。
- **`if a or b or c`** — 同理：只有最后一个 TEST（两个目标都不在本行）被报告。

> **为什么这种方式无法做指令级覆盖率？** C/gcov 在编译时插入弧计数器，可以逐条跟踪
> 每个分支指令。Lua 的行级调试钩子使得同一行的指令在运行时无法区分。若需真正的
> 指令级覆盖率（Lua 5.4+），请使用
> [pchook](#指令级分支覆盖率cluacovpchook--cluacovbranchcov)。

### 如何阅读 HTML 报告中的分支覆盖率

在 `genhtml` 生成的报告中，有分支的源码行会显示标注：

```
第 4 行    [+ +]:  2 :    if x > 0 then      -- 两条路径都走过
第 14 行   [+ #]:  1 :    if x < 0 then      -- 只走过一条路径
第 66 行   [# #]:  0 :    if a >= b then     -- 两条路径都没走过
```

- `+` = 该分支路径已执行
- `#` = 该分支路径**未执行**

## 生成 LCOV 报告

### LCOV 分支记录格式

每个分支目标对应一条 `BRDA` 记录：

```
BRDA:<行号>,<块ID>,<分支ID>,<命中次数>
```

- `行号` — 分支指令所在的源码行
- `块ID` — 分支站点的唯一标识
- `分支ID` — 0 或 1（两个目标中的哪一个）
- `命中次数` — 命中次数，未命中时为 `-`

汇总记录：

```
BRF:<分支目标总数>
BRH:<命中的分支目标数>
```

### 从 LCOV 生成 HTML

```sh
genhtml coverage.lcov --output-directory html --branch-coverage
```

### E2E 示例

`e2e/` 目录包含一个完整的工作示例：

```sh
lua e2e/e2e_branch_coverage.lua
```

该脚本会：
1. 在 LuaCov 下运行 `e2e/sample.lua`
2. 用 `deepbranches.get` 发现分支站点
3. 过滤复合条件分支
4. 与行命中数据交叉比对
5. 将 LCOV 写入 `e2e/output/coverage.lcov`
6. 生成 HTML 报告到 `e2e/output/html/`

## 平台支持

| 平台 | 分支分析 | 指令级 hook | 备注 |
|------|---------|-------------|------|
| PUC-Rio Lua 5.1 | 支持 | 不支持 | `OP_TFORLOOP` 后跟 `OP_JMP` |
| PUC-Rio Lua 5.2 | 支持 | 不支持 | `OP_TFORLOOP` 使用 `sBx` |
| PUC-Rio Lua 5.3 | 支持 | 不支持 | 同 5.2 |
| PUC-Rio Lua 5.4 | 支持 | 支持 | `OP_FORPREP` 条件化，`sJ` 格式跳转 |
| PUC-Rio Lua 5.5 | 支持 | 支持 | 同 5.4 |
| LuaJIT | 不支持 | 不支持 | 返回空表（字节码格式不同） |

## 指令级分支覆盖率（`cluacov.pchook` + `cluacov.branchcov`）

上述基于行命中的方法将同一行的多个分支视为不可区分（因为 Lua 调试钩子按行触发，
而非按指令触发）。为了实现**真正的指令级分支覆盖率**，cluacov 提供了 C 级别的
计数钩子，可以记录每条字节码指令的执行次数（per-PC 命中计数）。

### 为什么需要 per-PC？

考虑 `if a or b or c then`。这会编译为 3 条独立的 `TEST` 指令。
使用行命中数据时，3 条指令共享同一个命中计数——无法判断哪些子条件被求值。
使用 per-PC 计数时，每个 `TEST` 及其目标都有独立的命中计数，
分支目标数从 2 变为 6。

### `cluacov.pchook` API

```lua
local pchook = require("cluacov.pchook")

pchook.start()                     -- 注册指令级 C hook
-- ... 运行被测代码 ...
pchook.stop()                      -- 移除 hook

local hits = pchook.get_hits(func) -- 按 Proto 返回 PC 命中表
pchook.reset()                     -- 清空所有记录数据（采集继续运行）
```

`pchook.start()` 调用 `lua_sethook(L, hook, LUA_MASKCOUNT, 1)` 在每条 VM
指令执行时触发 C 级别回调。回调记录每条指令的 1-based 程序计数器，
以 `Proto*` 指针为键。

`pchook.get_hits(func)` 遍历函数的 Proto 树（包括嵌套函数），
返回一个条目数组：

```lua
{
    { linedefined = 0, sizecode = 42, hits = { [1] = 5, [3] = 2, ... } },
    { linedefined = 8, sizecode = 10, hits = { [2] = 3, ... } },
    ...
}
```

每个条目的 `hits` 表将 1-based PC 映射到执行次数。

> **性能提示：** 指令级钩子在每条 VM 指令上触发，但每次调用的开销低于
> cluacov C 行级钩子（无需调用 `lua_getstack`）——整体开销相当甚至更低
> （详见 [benchmark](../docs/benchmark.md)）。两种模式与无钩子基线相比
> 均有显著开销；请将 `pchook` 用于覆盖率分析，而非生产监控。

### `cluacov.branchcov` API

```lua
local branchcov = require("cluacov.branchcov")

local result = branchcov.analyze(func)
-- result.branches: 分支信息数组，每个目标有独立的命中计数
-- result.total: 分支目标总数（分支数 × 2）
-- result.hit: 命中次数 > 0 的目标数
```

`analyze` 组合 `deepbranches.get(func)` 和 `pchook.get_hits(func)` 来计算
指令级分支覆盖率。每个分支的目标都有来自 PC 级数据的独立 `hits` 计数。

与行命中方法不同，**不需要过滤**——每条分支指令都是可独立度量的。

### 共享目标 PC

多条分支指令可能共享同一个目标 PC（例如 `a or b or c` 中所有 `TEST`
都指向同一个函数体指令）。当函数体从任意路径到达时，该目标 PC 对**所有**
共享它的分支都显示为"已命中"。这是指令覆盖率（该 PC 是否被执行过？），
而非边覆盖率（从哪条分支到达？）。

### 要求

- 需要 **Lua 5.4+**（通过 vendored 头文件访问 `CallInfo.u.l.savedpc`）
- 传给 `get_hits` 的函数必须是在 `pchook.start()` 下**实际执行**的同一对象
  （相同的 `Proto*` 指针）
- Lua 5.1–5.3：`pchook.start()` 会报错；`get_hits()` 返回空表
- LuaJIT：同 5.1–5.3
