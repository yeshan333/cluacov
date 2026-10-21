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
| `loop-entry` | `for i = a, b`（入口，Lua >= 5.4 或 LuaJIT） | 数值 for 循环的初始入口判断 |
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
> 指令级覆盖率（Lua 5.4+ 或 LuaJIT 2.1），请使用
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

### 为什么有些 `end` 行有命中次数，有些却没标记为可执行

阅读 HTML 报告时常见的疑问：

```
   11         :   1 : end           ← 函数 end：       可执行，命中 1 次
   33         :     :    end        ← 简单 for end：   不可执行（留空）
   42         :   1 :    end        ← 带 break 的 for end： 可执行，命中 1 次
  126         :   1 :    end        ← 带闭包的 for end： 可执行，命中 1 次
  167         :     :       end     ← 简单 while end： 不可执行（留空）
   25         :     :    end        ← if 块的 end：    不可执行（留空）
```

这**不是 cluacov 的 bug**——而是 Lua 字节码层面的客观事实。一行源码会被
标记为"可执行"，当且仅当 Lua 编译器在编译时**真的为这一行发射了至少一条
字节码指令**（即该指令的 `lineinfo` 记录指回这一行）。`end` 关键字本身
并不是任何意义上的"语句"；它能不能进入行表，**完全取决于编译器是否有
任何清理或控制流指令需要绑定到这一行上**：

| `end` 的位置 | 该行绑定的字节码（如果有） | 是否可执行 |
|-------------|---------------------------|:---------:|
| **函数体的 `end`** | `OP_RETURN0`（隐式 `return nil`） | ✅ 总是 |
| **`if`/`elseif`/`else` 块的 `end`** | *（无——`then`/`else` 分支上的 `OP_JMP` 已经处理了控制流）* | ❌ 永不 |
| **`do ... end` 块的 `end`** | *（无）* | ❌ 永不 |
| **`repeat` 的 `until` 行** | until 条件测试（`LE`/`EQ`/`LT`）+ 回跳 `OP_JMP` | ✅ 总是 |
| **`for` 循环的 `end`（简单情况，无闭包捕获）** | *（无——`OP_FORLOOP`/`OP_TFORLOOP` 绑定到 `for` 那一行，**不绑定** `end` 行）* | ❌ 否 |
| **`for` 循环的 `end`（带 `break` + 需要 close 的局部变量）** | `OP_TFORLOOP`（5.5 把它绑到 `end` 行） | ✅ 是 |
| **`for` 循环的 `end`（循环体内有闭包捕获循环变量）** | `OP_CLOSE`（在作用域退出时关闭 upvalue） | ✅ 是 |
| **`while` 循环的 `end`（简单情况）** | *（无——回跳 `OP_JMP` 绑定到循环体的最后一行）* | ❌ 否 |
| **`while` 循环的 `end`（需要 close 闭包）** | `OP_CLOSE` | ✅ 是 |

直觉理解：函数 `end` 对应真实的运行时动作（RETURN）；`if-end` 和 `do-end`
是纯语法标记；而循环 `end` 是**条件性可执行的**——只有当编译器在作用域
退出时**确实有事可做**（关闭 upvalue，或者在某些 5.5 场景下需要锚定回跳
指令），才会有指令绑到这一行。对于无闭包捕获的"普通"循环，回跳指令绑到
循环体最后一行（不是 `end` 行），所以 `end` 行就留空了。

你可以用 `luac -l -p file.lua` 反汇编任何函数来亲自验证。来自
`e2e/sample.lua`（Lua 5.5）：

```
M.sum (L29-L35) —— 简单 for，无闭包：
  [31]  FORPREP  ...           ← 绑在 L31（`for` 行）
  [32]  GETTABLE/ADD/MMBIN     ← 绑在 L32（循环体）
  [31]  FORLOOP  ...            ← 绑在 L31（不是 L33——
                                  这就是为什么 L33 的 `end` 是留空的！）
  [34]  RETURN1  ...           ← 绑在 L34（`return total`）
  [35]  RETURN0  ...           ← 绑在 L35（函数 `end`）✅

M.if_block_first_line (L119-L128) —— for-in 带 break + 需 close 的局部：
  [126] CLOSE  2               ← 绑在 L126（for 的 `end`）✅
                                  这就是为什么 L126 是可执行的
  [128] RETURN ...             ← 绑在 L128（函数 `end`）✅
```

简单总结：**报告里所有有命中次数的 `end`，背后都对应着一条真实的指令
（RETURN、CLOSE、FORLOOP……）；所有留空的 `end`，仅仅是因为编译器没有
理由在那里发射任何代码。** 这与 `luacov`、`lcov`/`gcov` 以及其他 Lua
覆盖率工具的渲染方式保持一致，也让"覆盖行数"的分母更诚实——如果把空白的
`end` 都算成"未覆盖行"，反而会人为压低每个项目的覆盖率指标。

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
| LuaJIT 2.1 | 支持 | 支持 | 条件判断、数值循环、泛型迭代和 assert 调用 |

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

pchook.start()                     -- 注册指令级 C hook（active 期间重复调用是幂等的）
-- ... 运行被测代码 ...
pchook.stop()                      -- 移除 hook

local hits = pchook.get_hits(func) -- 按 Proto 返回 PC 命中表
pchook.reset()                     -- 清空所有记录数据（采集继续运行）
```

`pchook.start()` 安装 count=1 以及调用、返回 hook，记录每条指令的 1-based PC、
函数调用次数和同一次调用内相邻 PC 的跳转。内部用受 GC 管理的 Proto 弱键区分
独立函数，同一行的闭包不会串算，也不会持有闭包及其捕获对象。
去掉调试信息的字节码仍能累计 PC 命中，不会按指令不断创建记录。
若 hook 已经处于 active 状态，再次调用 `start()`
不会重置当前采样；`stop()` 后重新 `start()` 会继续累积现有数据，若要开启
新一轮采样应调用 `reset()`。

采集作用于整个 Lua 状态：`start()` 会给主线程和所有已有协程安装 hook，
包括已挂起的协程及 `coroutine.wrap` 闭包持有的协程。Lua 5.4 上有一个例外：
ltask 等宿主用 `lua_resume` 驱动主线程，若带 hook 的主线程挂起时关闭状态，
Lua 5.4 会中止所有 `__gc` 终结器，因此这类主线程只在由它自己调用 `start()`
时安装 hook。Lua 5.5 不受影响，始终给主线程安装 hook。若宿主直接在被
resume 的主线程上调用 `start()`，采集照常，但依赖终结器的退出落盘可能不生效；
请在关闭状态前显式保存（例如 `runner.save_stats()`）或使用 tick 模式。
新协程继承创建者的 hook。`stop()` 会先移除所有线程上的 cluacov hook，再固定报告数据；
若其他工具已经替换某个线程的 hook，则保留该替代 hook。
这些操作不替换 `coroutine.create`、`wrap` 或 `resume`。

采集器独占每个线程的 debug hook：`start()` 会覆盖启动前已有的 hook，
`stop()` 不会恢复它们。不要同时启用 LuaCov runner（例如 Busted 的 `-c`）、
调试器或其他依赖 hook 的采集器。保留启动后被替换的 hook 只是不干扰替换者，
不代表可以同时采集；被替换线程及继承该 hook 的子协程可能漏采。
仅记录采集期间执行的指令，不会补记启动前执行过的代码。

模块加载时会用 Lua 公共 API 校验分配器和 registry，并通过新建协程核验
GC 链表入口；检测到不匹配时会在遍历链表或安装 hook 前报错。
这不是完整的 ABI 兼容性保证：读取 `lua_State.l_G` 仍依赖标准布局，
自定义 Lua 构建必须使用匹配的内部头文件。

`pchook.get_hits(func)` 遍历函数的 Proto 树（包括嵌套函数），
返回一个条目数组：

```lua
{
    {
        linedefined = 0,
        lastlinedefined = 12,
        sizecode = 42,
        hits = { [1] = 5, [3] = 2, ... },
    },
    {
        linedefined = 8,
        lastlinedefined = 11,
        sizecode = 10,
        hits = { [2] = 3, ... },
    },
    ...
}
```

每个条目的 `hits` 表将 1-based PC 映射到执行次数。`calls` 记录采集期间观察到的
Lua 调用和尾调用事件，不会把入口处循环的迭代数当作调用数。启动采集前就已进入的
函数可以有指令命中而没有新的调用事件。`edges[from_pc][to_pc]` 记录同一次调用内的
PC 跳转；不同协程和调用帧互相隔离，不跨 stop/start 或 reset 拼接跳转。

`proto_id` 是供 `get_hits` 与 `deepbranches` 对应的临时身份，不应持久化。
`proto_path` 表示已观察到的 chunk 中的词法子函数路径，`signature` 用于与重载文件的
字节码匹配。全量快照只保留已复制的元数据和计数，不依赖存活的 Proto。
去掉调试信息后没有源码行归属，但 PC 和调用次数仍可查询。

> **性能提示：** 逐指令 hook、调用事件和跳转表均有时间与内存开销。
> [已有 benchmark](../docs/benchmark.md) 早于边计数实现，不能直接用于估计当前版本；
> 请按实际工作负载测量，并将该采集器用于覆盖率分析。

### `cluacov.branchcov` API

```lua
local branchcov = require("cluacov.branchcov")

local result = branchcov.analyze(func)
-- result.branches: 分支信息数组，每个目标有独立的命中计数
-- result.total: 分支目标总数（分支数 × 2）
-- result.hit: 命中次数 > 0 的目标数
```

`analyze` 组合 `deepbranches.get(func)` 和 `pchook.get_hits(func)` 来计算
分支边覆盖率。每个目标的 `hits` 是从该分支实际跳到目标的次数，
不是目标 PC 被任意路径执行的总次数。

与行命中方法不同，**不需要过滤**——每条分支指令都是可独立度量的。

### 共享目标 PC

多条分支可以共享目标 PC。采集器在同一次调用内记录跳转的起点和终点，
因此经 true 分支、goto 或其他短路条件到达汇合点，不会给另一条边增加命中。
被跳过的分支保持未覆盖。泛型循环的边计数也包含 Lua 5.4/5.5 融合进
`TFORPREP` 的第一次迭代。

内置 `assert` 的失败次数仍由已观察调用数减去成功返回到后续指令的次数得到。
静态 assert 识别依据名称，不验证运行时被调对象；把 assert 替换成可 yield 的
自定义函数不属于这一失败计数契约。

### Runner 报告和退出

函数列表来自完整 Proto 树，源码 token 只提供显示名称。缩进声明、赋值式函数、
冒号方法和匿名函数均会列入；注释和字符串不会制造函数记录。同名函数使用词法路径
后缀区分。FNDA 使用调用事件；延迟启动后的未覆盖行仍计入报告，每个函数起始行都有
供 genhtml 使用的 DA 标记。

建议先启动采集，再加载模块。报告用已观察到的词法路径和字节码签名匹配当前源码。
对于没有观察到根 chunk 的预加载函数，仅在签名匹配唯一时归属计数。
若同一行的相同函数在这种回退匹配中无法区分，或源码已经变化，runner 会告警并省略
这些函数的歧义函数/分支计数，避免串算。直接查询原始存活函数仍可区分其计数。

Tick 模式会周期保存，并在自然退出或 `os.exit()` 时最终保存一次。
如前文所述，宿主关闭带 hook 且已挂起的 Lua 5.4 主线程时，终结器可能不执行，
仍需在关闭状态前显式保存。

### 要求

- 需要 **Lua 5.4+ 或 LuaJIT 2.1**（使用仓库内的 VM 头文件）
- 传给 `get_hits` 的函数必须是在 `pchook.start()` 下**实际执行**过的同一对象
- `pchook.start()` 前后创建的协程，都能记录采集期间执行的代码。
  启动前已经执行过的代码不会补记。
- 每个线程只有一个调试 hook；采集期间若被其他采集器或调试器替换，
  该线程的覆盖率采集会中断。
- Lua 5.1–5.3：`pchook.start()` 会报错；`get_hits()` 返回空表
- LuaJIT 2.1：通过 `cluacov.runner` 采集指令级覆盖率


### LuaJIT 2.1

使用 `luajit -lcluacov.runner script.lua`，或调用前文相同的 `pchook`、
`branchcov` API。支持比较、真假判断、短路表达式、数值循环入口与回跳、
泛型迭代（包括 `pairs`/`next` 优化字节码）及非尾调用形式的 `assert`。
PC 从第一条可执行指令的 1 开始，不包含函数头指令。

`start()` 会清空已有 trace 并暂停 JIT，防止预热后的机器码绕过逐指令 hook。
`stop()` 恢复启动前 JIT 的开关状态；已清空的 trace 后续会重新编译。
采集期间不要调用 `jit.on()`。`deepbranches.get()` 若发现被检查的函数树有 trace，
也会清除它们以还原跳转参数，但不会改变 JIT 开关状态。

LuaJIT 的 hook 属于整个 VM。在任意协程中替换 hook 都会影响全部线程。
采集器启动时接管 hook，停止时不恢复启动前的 hook；对于启动后其他工具安装的
hook 则予以保留，但替换后的覆盖率数据不完整。

LuaJIT 禁止在 `__gc` 内切换 JIT 状态。因此在终结器里调用 `stop()` 时，
仍会冻结统计并写出报告，但 JIT 恢复会延后到普通上下文中的下一次 `stop()`。
短程序在第一次 tick 保存前退出也会写出最终报告。

适配器使用仓库内的 LuaJIT 2.1 对象布局及对应字节码、栈帧头文件；具体上游版本
见[英文说明](branch-coverage.md#luajit-21)。修改过对象或栈帧布局的 LuaJIT 分支
需要使用与运行时匹配的头文件。
