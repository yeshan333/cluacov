# Branch Coverage with `cluacov.deepbranches`

## Overview

`cluacov.deepbranches` statically analyzes Lua function bytecode to discover
**branch sites** — points where execution can take one of two paths. By
cross-referencing these sites with [LuaCov](https://github.com/lunarmodules/luacov)
line-hit data, you can compute branch coverage and generate LCOV reports with
branch records (`BRDA`).

## Supported Branch Types

| Kind | Source construct | Description |
|------|-----------------|-------------|
| `test` | `if`, `elseif`, `and`, `or`, comparisons | Conditional test followed by a jump |
| `loop` | `for i = a, b` (loop back edge) | Numeric for loop continuation check |
| `loop-entry` | `for i = a, b` (entry, Lua ≥ 5.4) | Numeric for loop initial entry check |
| `iterator` | `for k, v in f()` | Generic for iterator exhaustion check |

Each branch site has exactly **two targets**: the two possible execution paths.

## API

```lua
local deepbranches = require("cluacov.deepbranches")

-- deepbranches.version : string (e.g. "1.0.0")
-- deepbranches.get(func) -> table of branch sites

local branches = deepbranches.get(some_function)
```

`get` accepts a **Lua function** (not a C function) and returns an array of
branch site tables. It recursively includes branches from nested functions.

### Branch site fields

| Field | Type | Description |
|-------|------|-------------|
| `line` | number | Source line of the branch instruction |
| `pc` | number | 1-based program counter of the branch instruction |
| `kind` | string | Branch type: `"test"`, `"loop"`, `"loop-entry"`, or `"iterator"` |
| `linedefined` | number | First line of the enclosing function |
| `targets` | table | Array of exactly 2 target tables |

### Target fields

| Field | Type | Description |
|-------|------|-------------|
| `line` | number | Source line of the target instruction |
| `pc` | number | 1-based program counter of the target instruction |

### Example

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
         { line = 3, pc = 4 },   -- true  path: "return positive"
         { line = 5, pc = 6 },   -- false path: "return non-positive"
      }
   }
}
]]
```

## How Branch Coverage Works

Branch coverage measures whether **both paths** of each branch site were
exercised during testing.

The approach is:

1. **Discover** branch sites with `deepbranches.get(func)`
2. **Run** the code under LuaCov to collect per-line hit counts
3. **Merge** same-line branches into decisions (see below)
4. **Cross-reference**: for each decision, check if its outcome lines were hit

### Compound Conditions and Decision-Level Merging

Lua's debug hook fires at **line** level, not instruction level. When a single
source line contains multiple TEST instructions (e.g. `if a or b or c`),
`deepbranches.get` correctly returns 3 branch sites — but all share the same
line-hit count, so per-instruction coverage is impossible.

**Solution**: merge same-line branches into a single **decision**. For compound
conditions, only track targets on **different lines** from the branch line —
these are the actual observable outcomes (then-body vs else-body).

```
if a or b or c then   -- 3 branch sites, all on this line
   print("yes")       -- outcome 1 (off-line target)
else
   print("no")        -- outcome 2 (off-line target)
end
```

The merging algorithm:
- **Single branch on a line**: use both targets as-is (standard coverage)
- **Multiple branches on a line**: collect all target lines ≠ branch line,
  deduplicate → these become the decision's outcomes

```lua
-- Group branches by source line
local line_groups = {}
for _, branch in ipairs(branches) do
   line_groups[branch.line] = line_groups[branch.line] or {}
   table.insert(line_groups[branch.line], branch)
end

for line_nr, group in pairs(line_groups) do
   if #group == 1 then
      -- Simple: check both targets directly
   else
      -- Compound: collect off-line targets only
      local off_targets = {}
      for _, branch in ipairs(group) do
         for _, target in ipairs(branch.targets) do
            if target.line ~= line_nr then
               off_targets[target.line] = true
            end
         end
      end
      -- off_targets now has the 2 observable outcomes
   end
end
```

This matches **decision coverage** (DC) semantics: each Boolean decision
(potentially composed of multiple conditions) is covered when both its
true and false outcomes are exercised.

> **Why not instruction-level coverage?** C/gcov inserts arc counters at
> compile time, tracking every branch instruction individually. Lua only
> provides a line-level debug hook, so same-line instructions are
> indistinguishable at runtime. Decision-level merging is the most accurate
> coverage that Lua's runtime model can support.

### Reading branch coverage in HTML reports

In `genhtml`-generated reports, each source line with branches shows annotations:

```
Line 4    [+ +]:  2 :    if x > 0 then      -- both paths taken
Line 14   [+ #]:  1 :    if x < 0 then      -- only one path taken
Line 66   [# #]:  0 :    if a >= b then     -- neither path taken
```

- `+` = this branch path was taken
- `#` = this branch path was **not** taken (not executed)

## Generating LCOV Reports

### LCOV branch record format

Each branch target produces a `BRDA` record:

```
BRDA:<line>,<block_id>,<branch_id>,<taken>
```

- `line` — source line of the branch instruction
- `block_id` — unique ID for the branch site
- `branch_id` — 0 or 1 (which of the two targets)
- `taken` — hit count, or `-` if never taken

Summary records:

```
BRF:<total_branch_targets>
BRH:<hit_branch_targets>
```

### Generating HTML from LCOV

```sh
genhtml coverage.lcov --output-directory html --branch-coverage
```

### E2E example

The `e2e/` directory contains a complete working example:

```sh
lua e2e/e2e_branch_coverage.lua
```

This script:
1. Runs `e2e/sample.lua` under LuaCov
2. Discovers branch sites with `deepbranches.get`
3. Cross-references with line-hit data
4. Writes LCOV to `e2e/output/coverage.lcov`
5. Generates HTML report to `e2e/output/html/`

## Platform Support

| Platform | Branch analysis | Notes |
|----------|----------------|-------|
| PUC-Rio Lua 5.1 | Yes | `OP_TFORLOOP` followed by `OP_JMP` |
| PUC-Rio Lua 5.2 | Yes | `OP_TFORLOOP` uses `sBx` |
| PUC-Rio Lua 5.3 | Yes | Same as 5.2 |
| PUC-Rio Lua 5.4 | Yes | `OP_FORPREP` conditional, `sJ` format jumps |
| PUC-Rio Lua 5.5 | Yes | Same as 5.4 |
| LuaJIT | No | Returns empty table (bytecode format differs) |

---

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
| `loop-entry` | `for i = a, b`（入口，Lua ≥ 5.4） | 数值 for 循环的初始入口判断 |
| `iterator` | `for k, v in f()` | 泛型 for 迭代器的耗尽判断 |

每个分支站点恰好有**两个目标**：两条可能的执行路径。

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
3. 将同一行的分支**合并**为决策（见下文）
4. **交叉比对**：检查每个决策的结果行是否被命中

### 复合条件与决策级合并

Lua 的调试钩子在**行级别**触发，而非指令级别。当一行源码包含多个 TEST 指令时
（如 `if a or b or c`），`deepbranches.get` 会正确返回 3 个分支站点——但它们
共享相同的行命中计数，因此无法实现指令级的覆盖率统计。

**解决方案**：将同一行的分支合并为一个**决策**。对于复合条件，只跟踪与分支行
**不同行号**的目标——这些才是真正可观测的结果（then 分支体 vs else 分支体）。

```
if a or b or c then   -- 3 个分支站点，都在此行
   print("yes")       -- 结果 1（不同行的目标）
else
   print("no")        -- 结果 2（不同行的目标）
end
```

合并算法：
- **一行只有一个分支**：直接使用两个目标（标准覆盖率）
- **一行有多个分支**：收集所有目标行号 ≠ 分支行号的目标，去重后作为决策的结果

```lua
-- 按源码行号分组
local line_groups = {}
for _, branch in ipairs(branches) do
   line_groups[branch.line] = line_groups[branch.line] or {}
   table.insert(line_groups[branch.line], branch)
end

for line_nr, group in pairs(line_groups) do
   if #group == 1 then
      -- 简单情况：直接检查两个目标
   else
      -- 复合条件：只收集不同行的目标
      local off_targets = {}
      for _, branch in ipairs(group) do
         for _, target in ipairs(branch.targets) do
            if target.line ~= line_nr then
               off_targets[target.line] = true
            end
         end
      end
      -- off_targets 现在包含 2 个可观测的结果
   end
end
```

这符合**决策覆盖率**（Decision Coverage, DC）的语义：每个布尔决策（可能由多个
条件组合而成）在其 true 和 false 结果都被执行时算作"已覆盖"。

> **为什么不能做指令级覆盖率？** C/gcov 在编译时插入弧计数器，可以逐条跟踪
> 每个分支指令。Lua 只提供行级调试钩子，同一行的指令在运行时无法区分。
> 决策级合并是 Lua 运行时模型能支持的最精确的覆盖率。

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
3. 与行命中数据交叉比对
4. 将 LCOV 写入 `e2e/output/coverage.lcov`
5. 生成 HTML 报告到 `e2e/output/html/`

## 平台支持

| 平台 | 分支分析 | 备注 |
|------|---------|------|
| PUC-Rio Lua 5.1 | 支持 | `OP_TFORLOOP` 后跟 `OP_JMP` |
| PUC-Rio Lua 5.2 | 支持 | `OP_TFORLOOP` 使用 `sBx` |
| PUC-Rio Lua 5.3 | 支持 | 同 5.2 |
| PUC-Rio Lua 5.4 | 支持 | `OP_FORPREP` 条件化，`sJ` 格式跳转 |
| PUC-Rio Lua 5.5 | 支持 | 同 5.4 |
| LuaJIT | 不支持 | 返回空表（字节码格式不同） |
