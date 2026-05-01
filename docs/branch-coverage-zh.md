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

Lua 的调试钩子在**行级别**触发，而非指令级别。当一行源码包含多个分支指令时
（如 `if a or b or c` 编译为 3 条 TEST 指令），它们共享相同的行命中计数，
无法实现指令级的分支覆盖率统计。

**过滤规则**：对于同一行有多个分支的情况，只报告**两个目标都在不同行**的分支。
只有这种分支的两个结果才能通过行命中数据真正区分。目标在本行的分支（中间的
短路跳转）被跳过。当同一行多个分支共享相同的目标行对时，只报告一个（去重）。

这种方式自然处理了以下场景：

- **`if a and b`** — 最后一个 TEST 的目标分别在 then 体和 else 体（都不在本行），
  因此被报告。第一个 TEST 有一个目标在本行（跳到下一个 TEST），因此被跳过。
- **`for i = 1, n`** — FORPREP 和 FORLOOP 是同一行的两个分支指令，但两者的
  目标都不在本行（循环体和循环后）。因为它们共享相同的目标行对，只报告一个。
- **`if a or b or c`** — 同理：只有最后一个 TEST（两个目标都不在本行）被报告。

> **为什么不能做指令级覆盖率？** C/gcov 在编译时插入弧计数器，可以逐条跟踪
> 每个分支指令。Lua 只提供行级调试钩子，同一行的指令在运行时无法区分。

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

| 平台 | 分支分析 | 备注 |
|------|---------|------|
| PUC-Rio Lua 5.1 | 支持 | `OP_TFORLOOP` 后跟 `OP_JMP` |
| PUC-Rio Lua 5.2 | 支持 | `OP_TFORLOOP` 使用 `sBx` |
| PUC-Rio Lua 5.3 | 支持 | 同 5.2 |
| PUC-Rio Lua 5.4 | 支持 | `OP_FORPREP` 条件化，`sJ` 格式跳转 |
| PUC-Rio Lua 5.5 | 支持 | 同 5.4 |
| LuaJIT | 不支持 | 返回空表（字节码格式不同） |
