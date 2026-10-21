# 全项目覆盖率审查：已复现问题与补测清单

审查基线：`7487e36`，2026-10-21。阅读范围包括四个 C 扩展、三个 Lua 业务模块、现有 unit/E2E/native 测试及 CI 配置。运行环境为 macOS，Lua 5.4.8 和 5.5.0；本次没有运行其他 Lua 版本、Windows/Linux 或 sanitizer。

结论：确认 **8 类问题/行为缺口**，另有 **1 类文档已声明的 PC/edge 语义限制**。独立审查脚本包含 11 个场景：1 个正向对照通过、10 个预期行为断言失败，两版 Lua 结果一致。函数发现的两个失败场景归为同一类问题；已知语义限制不计入新增问题数量。

以上为修复前的审查记录；下文行号指向基线版本，不代表当前代码位置。

## 修复状态（2026-10-22）

八类问题均已修复，共享 PC 的误覆盖也改为按实际边计数。原 11 个反例全部通过，并扩展为 18 个进程隔离的报告/采集契约；另在 Busted 中新增 15 个回归场景。

- Proto 索引使用 GC 管理的弱键，不再用结构相似度合并独立函数，也不会持有闭包或其捕获对象。stop/start 保留索引；reset 只清空计数，不破坏 active/tick 状态。
- `calls` 来自调用/尾调用事件；`edges` 分协程和调用帧保存 PC 跳转，涵盖循环、递归、异常及首次泛型迭代。branchcov 和 runner 使用同一套边计数解释。
- 函数列表来自完整 Proto 树，显示名称来自跳过注释/字符串后的 token；同名函数有稳定后缀。LCOV 补齐未覆盖行及函数起始行的 DA 标记，genhtml 可以正常生成报告。
- Tick 模式增加最终保存。原有 suspended-main/finalizer 安全测试继续通过。
- 契约测试已接入 Lua 5.4/5.5 的三平台测试矩阵、ASan workflow 和本地 ASan mise 任务；实际远端 CI 尚未运行。

修复后的本地验证（macOS）：

| 验证 | Lua 5.4.8 | Lua 5.5.0 |
|---|---|---|
| Busted | 143 通过 | 143 通过 |
| 报告/采集契约 | 18 通过 | 18 通过 |
| 现有 E2E | 8/8 通过 | 8/8 通过 |
| 原生布局检查、挂起主线程关闭 | 通过 | 通过 |
| Clang ASan + UBSan：Busted + 17 个契约 | 通过 | 通过 |

ASan 使用独立的 C 扩展构建，堆越界阳性对照能被检测到；Lua 解释器本身使用现有安装版本。macOS 本地未运行 LSan，Docker 服务不可用，不能替代 Linux CI 的 LSan 结果。日志位于 `e2e/output/review/asan-<version>/`。

仍有明确边界：先加载后采集、根 chunk 身份已丢失且多个函数的签名完全相同时，runner 无法从源码重建它们的唯一对应关系，会告警并省略有歧义的函数/分支计数。直接查询原始存活函数仍正确；建议先启动采集再加载模块。自定义、可 yield 的 assert 也不属于内置 assert 的失败计数契约。

## 修复前的验证

| 验证 | Lua 5.4.8 | Lua 5.5.0 |
|---|---|---|
| 现有 Busted 单测 | 128 通过 | 128 通过 |
| 现有 E2E | 8/8 通过 | 8/8 通过 |
| 审查反例 | 1 通过 / 10 失败 | 1 通过 / 10 失败 |

单测使用 Lua 直接启动对应版本的 Busted Lua 入口，并以绝对 `LUA_PATH`/`LUA_CPATH` 指向本仓库源码和本地构建，避免 LuaRocks 的 Busted shell wrapper 把全局旧模块置于本地版本之前。E2E 按版本顺序运行，避免共用输出目录相互覆盖。

复现入口：[check_coverage_contracts.py](../../spec/native/check_coverage_contracts.py)。在仓库根目录运行：

```sh
rtk proxy env MISE_LUA_VERSION=5.4.8 mise exec -- luarocks make cluacov-dev-1.rockspec --tree=.
rtk proxy env MISE_LUA_VERSION=5.4.8 mise exec -- python3 spec/native/check_coverage_contracts.py

rtk proxy env MISE_LUA_VERSION=5.5.0 mise exec -- luarocks make cluacov-dev-1.rockspec --tree=.
rtk proxy env MISE_LUA_VERSION=5.5.0 mise exec -- python3 spec/native/check_coverage_contracts.py
```

当前脚本用于回归验证，正常退出码为 0。可用 `--case same_line_closures` 等参数单独运行。每个场景运行于独立进程和临时目录，结束后清理夹具。本次完整输出位于 `e2e/output/review/coverage-gaps-5.4.8.log` 和 `coverage-gaps-5.5.0.log`；这些日志是未纳入 Git 的本地产物。

## P1：去掉调试信息的字节码按指令新增记录

- 位置：`src/cluacov/pchook.c:241`，以及 `:343` 的查找/新建路径。
- 场景：用 `string.dump(f, true)` 去掉调试信息，同一个简单函数调用 100 次。
- 预期：一个 Proto 对应一条聚合记录，指令命中累计。
- 实测：`get_all_hits()['?']` 返回 **200 条记录**。
- 原因：无行号的 Proto 经 `get_pc_line()` 返回 `-1`，物化记录没有对应行号，`lua_tointeger(nil)` 得到 `0`；两者永不匹配。每次指令 hook 都把当前记录判为过期，再扫描旧记录并新建记录。
- 影响：记录数量随执行指令数增长，既破坏计数聚合，又使长时间执行的 stripped chunk 持续占用内存。按当前逐条查找逻辑推断，累计查找成本还会随记录增长显著恶化；本次没有做 OOM 或耗时阈值测试。
- 用例：`stripped_bytecode_records`。后续还应测 1/100/10000 次调用、GC 前后、带调试信息与去调试信息的同文件混用。

## P1：同一行的独立闭包串算覆盖率

- 位置：`src/cluacov/pchook.c:191`、`:343`；`src/cluacov/branchcov.lua:6`；`src/cluacov/runner.lua:125`。
- 场景：同一源码行定义两个独立函数，各有一个 if/else；第一个只调用 true，第二个只调用 false。
- 预期：两个函数分别为 `partial`。
- 实测：两个函数均为 **`covered`**，各分支的目标计数均为 1。把两个函数放到不同源码行的正向对照通过。
- 原因：采集器以 source、行范围、sizecode、行映射判断记录相同，但这些字段不是词法 Proto 的唯一身份。Lua 层的 `linedefined:lastlinedefined:sizecode` 键也有相同风险。增加 lastlinedefined 不能解决同一行兄弟闭包冲突。
- 影响：压缩源码、同一行的回调/dispatch 表等场景产生虚假的全覆盖。
- 用例：`same_line_closures`、`control_distinct_lines`。补测应覆盖只调用一个闭包、两个闭包取相反分支、同一行完全相同代码的独立闭包。修复要同时处理运行时身份和报告里的 Proto 对应关系。

## P2：以循环开头的函数，FNDA 把循环次数当调用次数

- 位置：`src/cluacov/runner.lua:246`。
- 场景：`spin(n)` 函数第一条语句是 `while n > 0 do n = n - 1 end`，只调用一次 `spin(3)`。
- 预期：`FNDA:1,spin`。
- 实测：**`FNDA:4,spin`**。
- 原因：第一个 PC 的命中次数不等于函数进入次数；循环回边可以再次执行第一个 PC。当前 `hits[1] or hits[2]` 还没有建立函数调用计数的独立依据。
- 用例：`loop_at_function_entry`。后续应覆盖 repeat-until、跳回入口的 goto、递归、尾调用及 vararg 入口，分别断言调用次数而非只检查 FNH 或 FNDA 大于零。

## P2：源码正则发现函数，既漏报又误报

- 位置：`src/cluacov/runner.lua:221`。
- 场景一：四个已调用函数分别使用缩进声明、赋值式声明、冒号方法和普通点号声明。
- 实测：**FNF/FNH 都是 2，预期都是 4**；冒号方法 `M:method` 被命名为 `M`。
- 场景二：长注释中包含 `function ghost()`，实际文件没有函数。
- 实测：**`FNF:1`、`FNDA:0,ghost`**，预期 FNF=0。
- 原因：行首正则既没有语法上下文，也没有覆盖函数表达式、缩进和冒号方法。函数覆盖率的分母会随排版和注释改变。
- 用例：`function_declaration_forms`、`comment_is_not_function`。后续还应覆盖两个不同表的同名方法、嵌套 local function、返回的匿名函数、长字符串、跨行声明。应以真实 Proto 发现函数，再单独决定稳定名称。

## P2：stop/start 后，未再次执行的函数查不到历史命中

- 位置：`src/cluacov/pchook.c:511`、`:615`。
- 场景：调用一次函数，stop，再 start/stop，第二阶段不调用该函数。
- 预期：按照累计采集契约，`get_hits(f)` 仍返回第一次调用的计数 1。
- 实测：入口命中从 **1 变成 0/缺失**。
- 原因：start 清空 Proto 指针索引，只有后续 hook 事件才重建映射；函数查询只查索引，不回查保留的记录。全量记录仍存在，这不是底层数据整体被清空。
- 用例：`restart_retains_function_hits`。现有 stop/start 测试在第二阶段再次调用函数，恰好重建索引，未暴露此问题。应同时比较 `get_hits`、`get_line_hits`、`get_all_hits` 和 `branchcov.analyze`。

## P2：branchcov API 将未执行的循环分支标成部分覆盖

- 位置：`src/cluacov/branchcov.lua:27`、`:42`；对照 `src/cluacov/runner.lua:286`。
- 场景：数字 for 的迭代数为零，FORPREP 直接跳过循环，FORLOOP 从未执行。
- 预期：`kind='loop'` 的分支为 `uncovered`。
- 实测：**`partial`**，因为循环后的共享目标 PC 执行过。
- 原因：runner 已检查分支源 PC 是否命中，branchcov.analyze 尚未做同样检查，两个出口行为不一致。
- 用例：`unreached_loop_branch`。补测应让同一夹具分别经过 API 与 runner LCOV，并逐项比较 BRDA/状态；短路跳过的测试和 goto 跳过的 assert 也应覆盖。

## P2：延迟启动时，LCOV 漏列后部未调用函数的行

- 位置：`src/cluacov/runner.lua:335`。
- 场景：先加载模块，再启动 runner，仅调用文件前部函数；文件后部还有未调用函数。
- 预期：后部函数体也输出 `DA:<line>,0`，计入 LF。
- 实测：报告只遍历到 **第 4 行**；第二个函数的 `FNDA:0,last` 存在，但其函数体第 6 行的 **DA 完全缺失**。
- 原因：虽然已经对完整文件调用 deepactivelines，输出循环上限却取已记录 Proto 的 `line_data.max`，未使用完整活动行集合。
- 用例：`late_start_uncalled_lines`。此场景不要求补记启动前的执行命中；要求的是正确列出未覆盖行。还应覆盖嵌入式宿主先加载后采集、reset 后只执行前部函数。

## P2：tick 模式在自然退出时不保存尾部数据

- 位置：`src/cluacov/runner.lua:399`、`:404`。
- 场景：`tick=true, savestepsize=1000000`，执行一个短程序后自然退出，不显式调用 `os.exit()` 或 `save_stats()`。
- 实测：进程 **exit=0，但 lcov.info 不存在**。
- 原因：tick 模式没有退出 GC anchor；自然退出不经过包装后的 os.exit。首个保存周期前没有任何报告，最后一个周期之后的执行也没有统一的最终刷新路径。
- 用例：`tick_natural_exit`。现有用例验证了周期回调和“不创建 anchor”，没有验证自然退出后的最终报告。
- 需要明确契约：实现兼容宿主关闭流程的最终保存，或者明确要求 tick 调用方自行 flush，并为两种退出方式及“保存后还有尾部调用”建立端到端断言。修复时必须保留已有 suspended-main/finalizer 安全测试。

## 原有语义限制（已修复）：PC 命中不能证明某条分支边走过

用例 `shared_target_edge_contract` 只执行 `if x then n=1 end` 的 true 路径，当前 API 返回 `covered`，按 edge coverage 应为 `partial`。false 路径的目标是汇合后的 return，而 true 路径同样会执行它。

修复前的文档已声明这种限制（[当前 Shared target PCs 小节](../branch-coverage.md#shared-target-pcs) 已说明新的边计数行为），`spec/branchcov_spec.lua:413` 也记录了 assert 汇合点的相似情况，因此不把它当成新发现的回归。但它影响“分支全覆盖”的解读，不能只展示每个目标都有命中就断言两条边都执行过。

本次选择增加调用帧内的边计数；这个反例现已通过，正式测试同时验证短路条件、goto 汇合点、循环入口和循环回边。

## 尚未实测、建议继续补充的场景

以下为风险驱动的测试建议，不是已确认缺陷。

| 优先级 | 场景 | 应观察的结果 |
|---|---|---|
| 高 | tick 回调抛错、调用 stop/reset/start；save_stats 写盘失败 | 业务错误传播、hook 状态、可重试保存行为都有明确契约 |
| 高 | `<close>` 变量正常关闭、错误展开、coroutine.close 触发抛错的 `__close` | 清理代码命中完整，异常后不出现错误归属或崩溃 |
| 高 | 分配器失败、统计表膨胀、频繁加载/卸载长函数 | 状态可恢复或明确报错；内存/运行时间增长可控；sanitizer 覆盖 |
| 中 | 执行后源码被修改/删除、工作目录改变，再保存 | 不把旧字节码计数静默套到新源码；缺失文件有可观察结果 |
| 中 | Windows 盘符/UNC、路径含空格/中文、同文件不同相对路径 | SF 路径正确、可被 genhtml 消费、同文件汇总策略明确 |
| 中 | 未加载文件、只创建不调用的闭包、匿名回调混在同一行 | LF/FNF/BRF 的统计范围明确，零覆盖不因没有执行记录而消失 |
| 中 | Lua 5.4 sanitizer E2E、Windows/macOS runner E2E | 现有 CI 的单测矩阵不应替代这些路径的原生验证 |

以上未实测项保留为后续测试建议；本轮已完成的范围和验证结果见修复状态。
