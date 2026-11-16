# v151–v178：帧缓冲画笔的追查与几何基线突破（2026-11-16）

> 这份卡记录 v150 之后到 v178 的画屏诊断。祖先文档见 `PENDING-FLASH-v137.md`（停在 v150）。
> 一句话结论：**画笔和显示几何从一开始就是对的；从 v165 起所有 mark 都画在
> `arm_vm_init()` 之后，而该调用切走 loader 的 identity VA `0xC3401000`，
> 所以十几版全都白画。v177 把 mark 挪到 `arm_vm_init()` 之前直写，6 条全出。**

## 一、实机 Geometry（务必按这个标定，别再改）

- fb 物理基址 `0x83401000`，stride `0xCA8`（1080px × 3B，24bpp），尺寸约 `0x23ff000`。
- 显示**垂直翻转**：fb 行号越大越靠屏幕上方。经验映射 `y ≈ 2052 − 0.935 × fb_row`（照片像素）。
- 可写行区（已实机证明）：band 8–12 = fb row 8..192；band 0–7 = row 200..680；
  band 13–21 = row 700..972。**新探针不要超过 row 972**。
- mark 画笔：`row = 700 + 45*i`（i=0..5），每条 30 行，纯写 `0xFFFFFFFF`，
  经 loader identity VA `0xC3401000`。6 条 = 累计打到第 6 级。

## 二、判读方法（血泪教训）

1. **照片里到处都是 loader 自己的黑白细条纹**（pitch 约 29px、每条约 12px 宽），
   千万别把它当成 mark。mark 的特征是：**6 条、间距约 39px、每条约 26px 宽、
   连续纯白占比 >0.9**。必须逐行剖面数连续性，不能凭肉眼。
2. **定位参考块（下部 row200..680 的大白块）必须用宽松白判据**：
   拍照白块偏粉，严格色差判据（如 `max-min<45`）只截到半截（252px），
   导致 fb row→照片坐标的 scale 全错，进而把 mark 位置判成"没出"。
   正确判据：`brightness>175 && (max-min)<80`，得到参考块高约 402–416px。
3. 每次改版后用 `patch -p1 --dry-run` 正反校验，series 只追加不回退，
   每版一个 `zzz-g0245d-vNNN-*.patch` + `build-vNNN-all.sh`。

## 三、根因链（逐版结论）

| 版本 | 做了什么 | 结果 / 结论 |
|---|---|---|
| v151–v163 | physmap / kPEAcquire 后画块 / halt / ml_io_map / pmap_map_bd 各种画笔 | 全灭。physmap 是 Normal cacheable，写留 cache，MDP5 DMA 读 DRAM 看不到；ml_io_map/pmap_map_bd 走 SPTM，`__assert_only` 静默失败 |
| v164 | 临时借 loader TTBR0 画 row700..972 | **出过白块**——第一次证明借 TTBR0 能画 |
| v165 | mark 统一改成 borrow 画笔 | 之后所有 mark 画在 arm_vm_init 之后，全部没出 |
| v166–v171 | 跳过 acquire 清屏 / 跳过 text console / MMSS 恢复 / keeper | 仍全黑；v169 halt 时仍黑 → 显示硬件层掉电嫌疑 |
| v172 | 移植 G0345D 的 TTBR1 fb slot（永久 device 属性映射） | **slot 从未装成**：地址 `VM_MAX_KERNEL_ADDRESS-0x10000000` 落在 `init_ptpages(cpu_tte, dynamic_memory_begin, VM_MAX_KERNEL_ADDRESS)` 已映射区 → `*l1_tte_fb` 非空 → `if(i==fb_blocks)` 全 EMPTY 检查失败 → `g0245d_fb_va` 恒为 0 |
| v173–v175 | 撤大白块露 mark / arm_init 末尾 mark / 5 级打点 | mark 一条不出；误以为是 console 或 slot 失效时机 |
| v176 | mark 改回 TTBR0 borrow | 依然一条不出。逐像素确认中部只有 loader 条纹 |
| **v177** | **6 条 mark 挪到 arm_vm_init 之前，用 loader VA 直写** | **6 条全部画出（决定性突破）**。证明画笔 + 几何全对，故障严格在 arm_vm_init 之后 |
| v178 | arm_vm_init 之后用同一 VA 把那 6 条涂黑 | **待判读**：变黑 ⇒ VA 存活、内核活着（之前是调用点问题）；仍白 ⇒ VA 跨不过 arm_vm_init / 内核在此 abort |

### 从 G0345D 继承来的三个 fb slot 陷阱（仍未解决，供后续修 slot 用）

1. `alloc_ptpage()` **不清零**，必须显式 `bzero()`。
2. 切换 TTBR0 前 `phystokv()` 不可靠，要用 `gVirtBase + (pa - gPhysBase)` 够到已有 L2 page。
3. 描述符物理基址 2MB 对齐而 fb 从块中间起，VA 必须加 `fb_pa - block_base` 块内偏移。

## 四、下一步（2026-11-17 接着干）

1. **先判读 v178**：看 v177 的 6 条白杠是否变黑，二选一：
   - 变黑 → loader VA 跨 arm_vm_init 有效、内核活着 → 把进度打点改成直写方式前移到 arm_vm_init 后，直接读内核推进阶段；
   - 仍白 → 必须建 arm_vm_init 后仍有效的永久 device 属性映射：修 v172 slot（强制覆盖那几个 L2 项，或另选未占用 VA），或先查内核是否在 arm_vm_init 里 abort。
2. 全程**无串口硬件**，不要再问 UART；只靠屏幕画带 + 照片判读推进。
3. 镜像 md5（备忘）：v177 `df6cf37c8351966bdf91ffebb0e023eb`，v178 `ce92b87f976a12180df9fce08a99e48b`。
