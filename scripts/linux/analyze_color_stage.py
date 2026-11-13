#!/usr/bin/env python3
"""v139 颜色探针判读：读冻屏/黑屏照片，判断屏幕停在哪一阶段。

v139 起 XNU 早期每过一个阶段就把整屏刷成一种纯色（而不是画累计白带），
所以只需看画面主体颜色即可定位死点：
    黄 = 进 arm_vm_init() 之前
    红 = arm_vm_init() 返回
    绿 = serial_init() 返回
    蓝 = PE_create_console() 返回
    白 = 即将进 machine_startup()
    黑 = 已越过白点（跑进 machine_startup 之后），或被更晚的代码清屏

用法: python3 analyze_color_stage.py <照片.jpg>
"""
import sys

try:
    from PIL import Image
except ImportError:
    sys.exit("需要 Pillow：用 /home/myth/.workbuddy/binaries/python/envs/default/bin/python 运行")

STAGES = [
    ("黄", (255, 255, 0), 21, "进 arm_vm_init() 之前 —— 即死在 arm_vm_init 之前的窗口"),
    ("红", (255, 0, 0), 22, "arm_vm_init() 已返回 —— 死在 serial_init() 之前/之中"),
    ("绿", (0, 255, 0), 23, "serial_init() 已返回 —— 死在 console 创建之前/之中"),
    ("蓝", (0, 0, 255), 24, "PE_create_console() 已返回 —— 死在进 machine_startup 之前"),
    ("白", (255, 255, 255), 25, "即将进 machine_startup() —— 已走完 arm_init 全程"),
]


def classify(rgb):
    r, g, b = rgb
    mx, mn = max(rgb), min(rgb)
    sat = 0 if mx == 0 else (mx - mn) / mx
    # 亮度优先：深灰/黑底（含 UEFI 菜单那种暗色界面）一律算黑
    if mx < 80:
        return ("黑", (0, 0, 0), 0, "屏幕全黑 —— 已越过白点（跑进 machine_startup 之后），"
                                  "或更晚的代码把屏清了；也可能显示被关")
    if sat < 0.22:
        if mx > 170:
            return ("白", (255, 255, 255), 25, "即将进 machine_startup() —— 已走完 arm_init 全程")
        return ("灰", (128, 128, 128), -1, "中间灰 —— 不像探针纯色，可能拍到的是 UEFI 菜单/"
                                          "过渡画面，或屏幕背光亮但内容已被清成深灰")
    # 按主通道定色
    best = min(STAGES[:4], key=lambda s: sum((a - b_) ** 2 for a, b_ in zip(rgb, s[1])))
    return (best[0], best[1], best[2], best[3])


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    path = sys.argv[1]
    im = Image.open(path).convert("RGB")
    w, h = im.size
    print(f"照片尺寸: {w}x{h}")

    # 取屏幕主体：中间 50% 宽、20%~75% 高（避开顶部绿条与底部条纹/手指）
    box = (int(w * 0.25), int(h * 0.20), int(w * 0.75), int(h * 0.72))
    crop = im.crop(box)
    # 用中位数抗反光/文字
    px = list(crop.getdata())
    px.sort(key=lambda p: p[0] + p[1] + p[2])
    med = px[len(px) // 2]
    avg = tuple(sum(p[i] for p in px[::7]) // len(px[::7]) for i in range(3))
    print(f"屏幕主体 中位色 RGB={med}  平均色 RGB={avg}")

    name, _ref, idx, desc = classify(med)
    print(f"\n>>> 判读结果: 【{name}】 (stage {idx})")
    print(f"    {desc}")

    # 分区块再看一遍，防止一半黑一半彩（清屏只清了一部分 / 照片构图偏）
    names = []
    for label, (y0, y1) in (("上部", (0.10, 0.35)), ("中部", (0.35, 0.60)), ("下部", (0.60, 0.85))):
        c = im.crop((int(w * 0.2), int(h * y0), int(w * 0.8), int(h * y1)))
        ps = sorted(c.getdata(), key=lambda p: p[0] + p[1] + p[2])
        m = ps[len(ps) // 2]
        n = classify(m)[0]
        names.append(f"{label}={n}{m}")
    print("分块: " + "  ".join(names))


if __name__ == "__main__":
    main()
