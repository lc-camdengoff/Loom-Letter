#!/usr/bin/env python3
"""
Loom Letter - title template generator.

Every Loom Letter title shares the same timing rig (intro/outro frames that adapt to the
clip length), so the .setting files are generated from the definitions below instead of
being edited by hand. Run after changing a preset:

    python3 tools/build_templates.py

then check the output with:

    luajit tools/validate_settings.lua "Fusion/Templates/Edit/Titles/Loom Letter/"*.setting

The generated files are committed, so Python is only needed when you change presets.
"""

from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT_DIR = ROOT / "Fusion" / "Templates" / "Edit" / "Titles" / "Loom Letter"


# --------------------------------------------------------------------------------------
# Tiny Lua-table serializer that writes Fusion-style .setting files
# --------------------------------------------------------------------------------------

class Ordered(dict):
    """Emitted as `ordered() { ... }` (Fusion keeps the key order)."""


class Typed:
    """Emitted as `Type { ... }`, e.g. Input { Value = 1 }."""

    def __init__(self, type_name: str, body: dict):
        self.type_name = type_name
        self.body = body


IDENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


def lua_str(s: str) -> str:
    s = s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\t", "\\t")
    return f'"{s}"'


def lua_num(n) -> str:
    if isinstance(n, bool):
        return "true" if n else "false"
    if isinstance(n, int):
        return str(n)
    r = repr(float(n))
    return r[:-2] if r.endswith(".0") else r


def is_inline(v) -> bool:
    return isinstance(v, (list, tuple)) and all(isinstance(x, (int, float)) for x in v)


def is_scalar(v) -> bool:
    return isinstance(v, (str, int, float, bool))


def emit(value, indent: int) -> str:
    if isinstance(value, Typed):
        body = value.body
        if not isinstance(body, Ordered) and all(is_scalar(v) or is_inline(v) for v in body.values()):
            one_line = ", ".join(f"{key_str(k)} = {emit(v, indent)}" for k, v in body.items())
            if len(one_line) <= 100:
                return f"{value.type_name} {{ {one_line}, }}"
        return f"{value.type_name} {emit_block(body, indent)}"
    if isinstance(value, dict):
        return emit_block(value, indent)
    if isinstance(value, (list, tuple)):
        return "{ " + ", ".join(emit(v, indent) for v in value) + " }"
    if isinstance(value, str):
        return lua_str(value)
    if isinstance(value, (int, float, bool)):
        return lua_num(value)
    raise TypeError(f"cannot serialize {value!r}")


def emit_block(d: dict, indent: int) -> str:
    tab = "\t"
    prefix = "ordered() " if isinstance(d, Ordered) else ""
    lines = [prefix + "{"]
    for k, v in d.items():
        lines.append(f"{tab * (indent + 1)}{key_str(k)} = {emit(v, indent + 1)},")
    lines.append(f"{tab * indent}}}")
    return "\n".join(lines)


def key_str(k: str) -> str:
    return k if IDENT.match(k) else f"[{lua_str(k)}]"


# --------------------------------------------------------------------------------------
# Building blocks
# --------------------------------------------------------------------------------------

def value(v):
    return Typed("Input", {"Value": v})


def expr(e, v=0):
    return Typed("Input", {"Value": v, "Expression": e})


def link(tool, output="Output"):
    return Typed("Input", {"SourceOp": tool, "Source": output})


def slider(name, default, lo, hi, integer=False, hidden=False, min_allowed=None):
    c = {
        "LINKS_Name": name,
        "LINKID_DataType": "Number",
        "INPID_InputControl": "SliderControl",
    }
    if integer:
        c["INP_Integer"] = True
    c["INP_MinScale"] = lo
    c["INP_MaxScale"] = hi
    if min_allowed is not None:
        c["INP_MinAllowed"] = min_allowed
    c["INP_Default"] = default
    if hidden:
        c["IC_Visible"] = False
    c["ICS_ControlPage"] = "Controls"
    return c


def checkbox(name, default):
    return {
        "LINKS_Name": name,
        "LINKID_DataType": "Number",
        "INPID_InputControl": "CheckboxControl",
        "INP_Integer": True,
        "INP_Default": default,
        "ICS_ControlPage": "Controls",
    }


def textbox(name, lines=3):
    return {
        "LINKS_Name": name,
        "LINKID_DataType": "Text",
        "INPID_InputControl": "TextEditControl",
        "TEC_Lines": lines,
        "ICS_ControlPage": "Controls",
    }


def tool(type_name, inputs, pos, user_controls=None):
    body = {"CtrlWZoom": False, "NameSet": True, "Inputs": inputs,
            "ViewInfo": Typed("OperatorInfo", {"Pos": list(pos)})}
    if user_controls:
        body["UserControls"] = Ordered(user_controls)
    return Typed(type_name, body)


def timing_rig(host: str, intro: int, outro: int):
    """Hidden helpers every title uses. All values are 0..1.

    RevealIn  rises 0 -> 1 over the first `InFrames` frames of the clip.
    RevealOut falls 1 -> 0 over the last `OutFrames` frames of the clip.
    EaseIn/EaseOut are cubic ease-out versions (snappy arrival, accelerating exit).
    Ease is the combined visibility.
    Using comp.RenderStart/RenderEnd means the animation follows the clip when it is
    trimmed on the Edit page.
    """
    h = host
    # (t - start) / frames, except that 0 frames means "fully visible from the first frame"
    # without ever dividing by zero.
    inputs = {
        "InFrames": value(intro),
        "OutFrames": value(outro),
        "RevealIn": expr(f"min(max((time - comp.RenderStart + 1 - min({h}.InFrames, 1)) / max({h}.InFrames, 1), 0), 1)", 1),
        "RevealOut": expr(f"min(max((comp.RenderEnd - time + 1 - min({h}.OutFrames, 1)) / max({h}.OutFrames, 1), 0), 1)", 1),
        "EaseIn": expr(f"1 - (1 - {h}.RevealIn) * (1 - {h}.RevealIn) * (1 - {h}.RevealIn)", 1),
        "EaseOut": expr(f"1 - (1 - {h}.RevealOut) * (1 - {h}.RevealOut) * (1 - {h}.RevealOut)", 1),
        "Ease": expr(f"min({h}.EaseIn, {h}.EaseOut)", 1),
    }
    controls = {
        "InFrames": slider("Intro Frames", intro, 0, 60, integer=True, min_allowed=0),
        "OutFrames": slider("Outro Frames", outro, 0, 60, integer=True, min_allowed=0),
        "RevealIn": slider("Reveal In", 1, 0, 1, hidden=True),
        "RevealOut": slider("Reveal Out", 1, 0, 1, hidden=True),
        "EaseIn": slider("Ease In", 1, 0, 1, hidden=True),
        "EaseOut": slider("Ease Out", 1, 0, 1, hidden=True),
        "Ease": slider("Ease", 1, 0, 1, hidden=True),
    }
    return inputs, controls


def text_inputs(text, size, font="Open Sans", style="Bold", center=(0.5, 0.5), rgb=(1, 1, 1),
                left=False, spacing=1.0):
    d = {
        "UseFrameFormatSettings": value(1),
        "StyledText": value(text),
        "Font": value(font),
        "Style": value(style),
        "Size": value(size),
        "CharacterSpacing": value(spacing),
        "Red1": value(rgb[0]),
        "Green1": value(rgb[1]),
        "Blue1": value(rgb[2]),
        "Center": value(list(center)),
    }
    if left:
        d["HorizontalLeftCenterRight"] = value(-1)
    return d


def canvas(pos):
    return tool("Background", {"UseFrameFormatSettings": value(1), "TopLeftAlpha": value(0)}, pos)


def instance(tool_name, source, name=None, group=None, default=None):
    d = {"SourceOp": tool_name, "Source": source}
    if name:
        d["Name"] = name
    if group is not None:
        d["ControlGroup"] = group
    if default is not None:
        d["Default"] = default
    return d


def text_controls(host, first_index, include_spacing=True, text_source="StyledText"):
    """Standard exposed controls: text, font, size, (tracking), colour, position."""
    items = [
        instance(host, text_source),
        instance(host, "Font", group=first_index + 1),
        instance(host, "Style", group=first_index + 1),
        instance(host, "Size"),
    ]
    if include_spacing:
        items.append(instance(host, "CharacterSpacing", name="Tracking"))
    g = first_index + len(items)
    items += [
        instance(host, "Red1", name="Color", group=g, default=1),
        instance(host, "Green1", group=g, default=1),
        instance(host, "Blue1", group=g, default=1),
        instance(host, "Center", name="Position"),
    ]
    return items


def macro(name, exposed, output_tool, tools):
    inputs = Ordered()
    for i, ii in enumerate(exposed, start=1):
        inputs[f"Input{i}"] = Typed("InstanceInput", ii)
    body = {
        "CtrlWZoom": False,
        "NameSet": True,
        "Inputs": inputs,
        "Outputs": {"MainOutput1": Typed("InstanceOutput", {"SourceOp": output_tool, "Source": "Output"})},
        "ViewInfo": Typed("GroupInfo", {"Pos": [0, 0]}),
        "Tools": Ordered(tools),
    }
    return {"Tools": Ordered({name: Typed("MacroOperator", body)}), "ActiveTool": name}


# --------------------------------------------------------------------------------------
# Presets
# --------------------------------------------------------------------------------------

def slide_up():
    h = "Title"
    t_in, t_ui = timing_rig(h, 15, 12)
    inputs = text_inputs("YOUR TITLE HERE", 0.08)
    inputs.update(t_in)
    inputs["Distance"] = value(0.06)
    ui = dict(t_ui)
    ui["Distance"] = slider("Slide Distance", 0.06, 0, 0.3)
    tools = {
        h: tool("TextPlus", inputs, (0, 0), ui),
        "Slide": tool("Transform", {
            "Center": expr(f"Point(0.5, 0.5 - (1 - {h}.EaseIn) * {h}.Distance + (1 - {h}.EaseOut) * {h}.Distance)",
                           [0.5, 0.5]),
            "MotionBlur": value(1),
            "Quality": value(5),
            "Input": link(h),
        }, (110, 0)),
        "Canvas": canvas((220, -49.5)),
        "Fade": tool("Merge", {
            "Background": link("Canvas"),
            "Foreground": link("Slide"),
            "Blend": expr(f"{h}.Ease", 1),
            "PerformDepthMerge": value(0),
        }, (220, 0)),
    }
    exposed = text_controls(h, 1) + [
        instance(h, "InFrames", default=15),
        instance(h, "OutFrames", default=12),
        instance(h, "Distance", default=0.06),
    ]
    return macro("LL_SlideUp", exposed, "Fade", tools)


def blur_in():
    h = "Title"
    t_in, t_ui = timing_rig(h, 18, 12)
    inputs = text_inputs("YOUR TITLE HERE", 0.08, spacing=1.05)
    inputs.update(t_in)
    inputs["BlurAmount"] = value(12)
    inputs["ScaleAmount"] = value(0.12)
    ui = dict(t_ui)
    ui["BlurAmount"] = slider("Blur Amount", 12, 0, 40)
    ui["ScaleAmount"] = slider("Scale Amount", 0.12, 0, 0.5)
    tools = {
        h: tool("TextPlus", inputs, (0, 0), ui),
        "Soften": tool("Blur", {
            "XBlurSize": expr(f"(1 - {h}.Ease) * {h}.BlurAmount", 0),
            "Input": link(h),
        }, (110, 0)),
        "Scale": tool("Transform", {
            "Center": expr(f"Point({h}.Center.X, {h}.Center.Y)", [0.5, 0.5]),
            "Pivot": expr(f"Point({h}.Center.X, {h}.Center.Y)", [0.5, 0.5]),
            "Size": expr(f"1 + (1 - {h}.Ease) * {h}.ScaleAmount", 1),
            "Input": link("Soften"),
        }, (220, 0)),
        "Canvas": canvas((330, -49.5)),
        "Fade": tool("Merge", {
            "Background": link("Canvas"),
            "Foreground": link("Scale"),
            "Blend": expr(f"{h}.Ease", 1),
            "PerformDepthMerge": value(0),
        }, (330, 0)),
    }
    exposed = text_controls(h, 1) + [
        instance(h, "InFrames", default=18),
        instance(h, "OutFrames", default=12),
        instance(h, "BlurAmount", default=12),
        instance(h, "ScaleAmount", default=0.12),
    ]
    return macro("LL_BlurIn", exposed, "Fade", tools)


def back_out(v):
    """easeOutBack with the classic 1.70158 overshoot, written out for Fusion expressions."""
    return f"1 + 2.70158 * ({v} - 1) * ({v} - 1) * ({v} - 1) + 1.70158 * ({v} - 1) * ({v} - 1)"


def pop():
    h = "Title"
    t_in, t_ui = timing_rig(h, 12, 8)
    inputs = text_inputs("POP!", 0.12)
    inputs.update(t_in)
    inputs["PopIn"] = expr(back_out(f"{h}.RevealIn"), 1)
    inputs["PopOut"] = expr(back_out(f"{h}.RevealOut"), 1)
    ui = dict(t_ui)
    ui["PopIn"] = slider("Pop In", 1, 0, 1.2, hidden=True)
    ui["PopOut"] = slider("Pop Out", 1, 0, 1.2, hidden=True)
    tools = {
        h: tool("TextPlus", inputs, (0, 0), ui),
        "Bounce": tool("Transform", {
            "Center": expr(f"Point({h}.Center.X, {h}.Center.Y)", [0.5, 0.5]),
            "Pivot": expr(f"Point({h}.Center.X, {h}.Center.Y)", [0.5, 0.5]),
            "Size": expr(f"max({h}.PopIn * {h}.PopOut, 0)", 1),
            "MotionBlur": value(1),
            "Quality": value(5),
            "Input": link(h),
        }, (110, 0)),
        "Canvas": canvas((220, -49.5)),
        "Fade": tool("Merge", {
            "Background": link("Canvas"),
            "Foreground": link("Bounce"),
            "Blend": expr(f"min(min({h}.RevealIn * 3, 1), min({h}.RevealOut * 3, 1))", 1),
            "PerformDepthMerge": value(0),
        }, (220, 0)),
    }
    exposed = text_controls(h, 1) + [
        instance(h, "InFrames", default=12),
        instance(h, "OutFrames", default=8),
    ]
    return macro("LL_Pop", exposed, "Fade", tools)


def tracking():
    h = "Title"
    t_in, t_ui = timing_rig(h, 30, 15)
    inputs = text_inputs("CINEMATIC", 0.075, style="Regular")
    inputs.update(t_in)
    inputs["Tracking"] = value(1.25)
    inputs["Spread"] = value(0.6)
    inputs["CharacterSpacing"] = expr(f"{h}.Tracking + (1 - {h}.Ease) * {h}.Spread", 1.25)
    ui = dict(t_ui)
    ui["Tracking"] = slider("Final Tracking", 1.25, 0.8, 2)
    ui["Spread"] = slider("Tracking Spread", 0.6, 0, 2)
    tools = {
        h: tool("TextPlus", inputs, (0, 0), ui),
        "Soften": tool("Blur", {
            "XBlurSize": expr(f"(1 - {h}.Ease) * 6", 0),
            "Input": link(h),
        }, (110, 0)),
        "Canvas": canvas((220, -49.5)),
        "Fade": tool("Merge", {
            "Background": link("Canvas"),
            "Foreground": link("Soften"),
            "Blend": expr(f"{h}.Ease", 1),
            "PerformDepthMerge": value(0),
        }, (220, 0)),
    }
    exposed = text_controls(h, 1, include_spacing=False) + [
        instance(h, "Tracking", default=1.25),
        instance(h, "Spread", default=0.6),
        instance(h, "InFrames", default=30),
        instance(h, "OutFrames", default=15),
    ]
    return macro("LL_Tracking", exposed, "Fade", tools)


TYPEWRITER_EXPR = "\n".join([
    ":local s = tostring(Title.Message.Value or \"\")",
    "local start = 0",
    "if comp then start = comp.RenderStart end",
    "local chars = {}",
    "for ch in s:gmatch(\"[%z\\1-\\127\\194-\\244][\\128-\\191]*\") do chars[#chars + 1] = ch end",
    "local n = math.floor((time - start) * Title.Speed + 0.0001)",
    "if n < 0 then n = 0 end",
    "if n > #chars then n = #chars end",
    "local out = table.concat(chars, \"\", 1, n)",
    "if Title.Cursor > 0.5 and (n < #chars or math.floor(time / 8) % 2 == 0) then out = out .. \"_\" end",
    "return out",
])


def typewriter():
    h = "Title"
    t_in, t_ui = timing_rig(h, 0, 10)
    inputs = text_inputs("", 0.06, font="Courier New", style="Regular", center=(0.2, 0.5), left=True)
    inputs["StyledText"] = expr(TYPEWRITER_EXPR, "")
    inputs.update(t_in)
    inputs["Message"] = value("Type your message here")
    inputs["Speed"] = value(0.6)
    inputs["Cursor"] = value(1)
    ui = {"Message": textbox("Message")}
    ui.update(t_ui)
    ui["Speed"] = slider("Typing Speed (chars/frame)", 0.6, 0.05, 3)
    ui["Cursor"] = checkbox("Show Cursor", 1)
    tools = {
        h: tool("TextPlus", inputs, (0, 0), ui),
        "Canvas": canvas((110, -49.5)),
        "Fade": tool("Merge", {
            "Background": link("Canvas"),
            "Foreground": link(h),
            "Blend": expr(f"{h}.EaseOut", 1),
            "PerformDepthMerge": value(0),
        }, (110, 0)),
    }
    exposed = text_controls(h, 1, include_spacing=True, text_source="Message") + [
        instance(h, "Speed", default=0.6),
        instance(h, "Cursor", default=1),
        instance(h, "OutFrames", default=10),
    ]
    return macro("LL_Typewriter", exposed, "Fade", tools)


def lower_third():
    h = "NameText"
    t_in, t_ui = timing_rig(h, 18, 12)
    name_inputs = text_inputs("JANE DOE", 0.045, center=(0.105, 0.225), left=True)
    name_inputs.update(t_in)
    name_inputs["Slide"] = value(0.1)
    name_inputs["BarHeight"] = value(0.09)
    ui = dict(t_ui)
    ui["Slide"] = slider("Slide Distance", 0.1, 0, 0.3)
    ui["BarHeight"] = slider("Bar Height", 0.09, 0, 0.3)
    role_inputs = text_inputs("Title / Role", 0.03, style="Regular", center=(0.105, 0.175),
                              rgb=(0.85, 0.85, 0.85), left=True)
    slide_x = f"(1 - {h}.EaseIn) * {h}.Slide + (1 - {h}.EaseOut) * {h}.Slide"
    tools = {
        h: tool("TextPlus", name_inputs, (0, 0), ui),
        "RoleText": tool("TextPlus", role_inputs, (0, 49.5)),
        "NameMove": tool("Transform", {
            "Center": expr(f"Point(0.5 - {slide_x}, 0.5)", [0.5, 0.5]),
            "MotionBlur": value(1),
            "Quality": value(5),
            "Input": link(h),
        }, (110, 0)),
        "RoleMove": tool("Transform", {
            "Center": expr(f"Point(0.5 - {slide_x}, 0.5)", [0.5, 0.5]),
            "MotionBlur": value(1),
            "Quality": value(5),
            "Input": link("RoleText"),
        }, (110, 49.5)),
        "BarMask": tool("RectangleMask", {
            "Center": value([0.09, 0.2]),
            "Width": value(0.005),
            "Height": expr(f"{h}.Ease * {h}.BarHeight", 0.09),
        }, (220, -99)),
        "RevealMask": tool("RectangleMask", {
            "Center": value([0.593, 0.2]),
            "Width": value(1.0),
            "Height": value(0.25),
        }, (330, -99)),
        "Canvas": canvas((220, -148.5)),
        "Accent": tool("Background", {
            "UseFrameFormatSettings": value(1),
            "TopLeftRed": value(0.96),
            "TopLeftGreen": value(0.7),
            "TopLeftBlue": value(0.0),
            "EffectMask": link("BarMask", "Mask"),
        }, (220, -49.5)),
        "BarOver": tool("Merge", {
            "Background": link("Canvas"),
            "Foreground": link("Accent"),
            "PerformDepthMerge": value(0),
        }, (330, -49.5)),
        "NameOver": tool("Merge", {
            "Background": link("BarOver"),
            "Foreground": link("NameMove"),
            "Blend": expr(f"{h}.Ease", 1),
            "EffectMask": link("RevealMask", "Mask"),
            "PerformDepthMerge": value(0),
        }, (440, 0)),
        "RoleOver": tool("Merge", {
            "Background": link("NameOver"),
            "Foreground": link("RoleMove"),
            "Blend": expr(f"{h}.Ease", 1),
            "EffectMask": link("RevealMask", "Mask"),
            "PerformDepthMerge": value(0),
        }, (550, 0)),
        "Place": tool("Transform", {
            "Input": link("RoleOver"),
        }, (660, 0)),
    }
    exposed = [
        instance(h, "StyledText", name="Name"),
        instance("RoleText", "StyledText", name="Role"),
        instance(h, "Font", name="Name Font", group=3),
        instance(h, "Style", group=3),
        instance("RoleText", "Font", name="Role Font", group=5),
        instance("RoleText", "Style", group=5),
        instance(h, "Size", name="Name Size"),
        instance("RoleText", "Size", name="Role Size"),
        instance(h, "Red1", name="Name Color", group=9, default=1),
        instance(h, "Green1", group=9, default=1),
        instance(h, "Blue1", group=9, default=1),
        instance("RoleText", "Red1", name="Role Color", group=12, default=0.85),
        instance("RoleText", "Green1", group=12, default=0.85),
        instance("RoleText", "Blue1", group=12, default=0.85),
        instance("Accent", "TopLeftRed", name="Accent Color", group=15, default=0.96),
        instance("Accent", "TopLeftGreen", group=15, default=0.7),
        instance("Accent", "TopLeftBlue", group=15, default=0.0),
        instance("Place", "Center", name="Position"),
        instance(h, "InFrames", default=18),
        instance(h, "OutFrames", default=12),
        instance(h, "Slide", default=0.1),
        instance(h, "BarHeight", default=0.09),
    ]
    return macro("LL_LowerThird", exposed, "Place", tools)


PRESETS = {
    "LL Slide Up": slide_up,
    "LL Blur In": blur_in,
    "LL Pop": pop,
    "LL Tracking": tracking,
    "LL Typewriter": typewriter,
    "LL Lower Third": lower_third,
}


def main():
    import sys
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    sys.modules.setdefault("build_templates", sys.modules[__name__])  # share classes with the library
    from library_presets import LIBRARY  # noqa: E402 - imports helpers from this module
    PRESETS.update(LIBRARY)
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    for name, build in PRESETS.items():
        text = emit(build(), 0) + "\n"
        path = OUT_DIR / f"{name}.setting"
        path.write_text(text, encoding="utf-8", newline="\n")
        print(f"wrote {path.relative_to(ROOT)}")
    stale = {p.name for p in OUT_DIR.glob("*.setting")} - {f"{n}.setting" for n in PRESETS}
    for s in sorted(stale):
        print(f"note: {s} is not produced by this generator")


if __name__ == "__main__":
    main()
