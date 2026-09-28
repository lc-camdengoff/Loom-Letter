"""
Loom Letter - preset library (Essential Typography, Social, Counters, Cinematic, Shapes).

Imported by build_templates.py. Every preset is built with the `Rig` helper below, which
owns the shared timing rig, the layer stack and the exposed Inspector controls.

Conventions
- The "host" tool carries the timing rig and all preset controls. It is the main Text+
  (named "Title") for text presets and the transparent "Canvas" for shape presets.
- `Vis` is a hidden host control describing the preset's overall visibility. The
  validator checks it is 0 on the first and last frame (and 1 mid-clip, except for shape
  bursts, which only play for `BurstFrames`).
- Mask sizes are in Fusion's mask units; vertical positions assume a 16:9 frame.
"""

from __future__ import annotations

from build_templates import (Ordered, Typed, checkbox, expr, instance, link, macro, slider,
                             text_inputs, textbox, timing_rig, tool, value)

ACCENT = (0.96, 0.7, 0.0)
WHITE = (1, 1, 1)
DARK = (0.08, 0.08, 0.1)


def back_out(v):
    return f"(1 + 2.70158 * ({v} - 1) * ({v} - 1) * ({v} - 1) + 1.70158 * ({v} - 1) * ({v} - 1))"


def clamp01(e):
    return f"min(max({e}, 0), 1)"


class Rig:
    def __init__(self, macro_name, intro=15, outro=12, host="Title", host_inputs=None, shape=False):
        self.macro_name = macro_name
        self.h = host
        self.shape = shape
        rig_in, rig_ui = timing_rig(host, intro, outro)
        if shape:
            base = {"UseFrameFormatSettings": value(1), "TopLeftAlpha": value(0)}
        else:
            base = dict(host_inputs or {})
        base.update(rig_in)
        self.host_inputs = base
        self.host_ui = dict(rig_ui)
        self.tools = {}
        self.exposed = []
        self.x = 110
        self.y = 0
        self.layers = []

    # host controls -------------------------------------------------------------------
    def control(self, name, label, default, lo=0, hi=1, integer=False, hidden=False, formula=None):
        self.host_inputs[name] = expr(formula, default) if formula else value(default)
        self.host_ui[name] = slider(label, default, lo, hi, integer=integer, hidden=hidden,
                                    min_allowed=0 if integer else None)
        return f"{self.h}.{name}"

    def hidden(self, name, formula, default=1):
        return self.control(name, name, default, hidden=True, formula=formula)

    def flag(self, name, label, default):
        self.host_inputs[name] = value(default)
        self.host_ui[name] = checkbox(label, default)
        return f"{self.h}.{name}"

    def text_control(self, name, label, default):
        self.host_inputs[name] = value(default)
        self.host_ui[name] = textbox(label, lines=1)
        return f"{self.h}.{name}"

    def burst(self, frames=24, delay=0):
        """Shape timing: P goes 0 -> 1 over BurstFrames after Delay."""
        h = self.h
        self.control("BurstFrames", "Burst Frames", frames, 1, 90, integer=True)
        self.control("Delay", "Delay Frames", delay, 0, 60, integer=True)
        self.hidden("P", clamp01(f"(time - comp.RenderStart - {h}.Delay) / max({h}.BurstFrames, 1)"), 0)
        self.hidden("E", f"1 - (1 - {h}.P) * (1 - {h}.P) * (1 - {h}.P)", 0)

    def pops(self):
        h = self.h
        self.hidden("PopIn", back_out(f"{h}.RevealIn"))
        self.hidden("PopOut", back_out(f"{h}.RevealOut"))
        return f"max({h}.PopIn * {h}.PopOut, 0)"

    # tools -----------------------------------------------------------------------------
    def add(self, name, type_name, inputs, ui=None):
        self.tools[name] = tool(type_name, inputs, (self.x, self.y), ui)
        self.x += 110
        return name

    def text(self, name, text, size, **kw):
        return self.add(name, "TextPlus", text_inputs(text, size, **kw))

    def mask(self, name, kind, center, width, height, **extra):
        inputs = {"Center": _v(center), "Width": _v(width), "Height": _v(height)}
        for k, v in extra.items():
            inputs[k] = _v(v)
        return self.add(name, kind, inputs)

    def fill(self, name, rgb, mask_name, alpha=1.0):
        return self.add(name, "Background", {
            "UseFrameFormatSettings": value(1),
            "TopLeftRed": value(rgb[0]), "TopLeftGreen": value(rgb[1]), "TopLeftBlue": value(rgb[2]),
            "TopLeftAlpha": value(alpha),
            "EffectMask": link(mask_name, "Mask"),
        })

    def xf(self, name, source, center=None, size=None, angle=None, pivot=None, blur_motion=False):
        inputs = {"Input": link(source)}
        if center is not None:
            inputs["Center"] = _v(center, [0.5, 0.5])
        if pivot is not None:
            inputs["Pivot"] = _v(pivot, [0.5, 0.5])
        if size is not None:
            inputs["Size"] = _v(size, 1)
        if angle is not None:
            inputs["Angle"] = _v(angle, 0)
        if blur_motion:
            inputs["MotionBlur"] = value(1)
            inputs["Quality"] = value(5)
        return self.add(name, "Transform", inputs)

    def blur(self, name, source, amount):
        return self.add(name, "Blur", {"Input": link(source), "XBlurSize": _v(amount, 0)})

    def gain(self, name, source, amount):
        return self.add(name, "BrightnessContrast", {"Input": link(source), "Gain": _v(amount, 1)})

    def layer(self, source, blend=None, clip=None):
        self.layers.append((source, blend, clip))

    # exposing ------------------------------------------------------------------------
    def expose(self, tool_name, source, name=None, default=None, group=False):
        g = len(self.exposed) + 1 if group else None
        self.exposed.append(instance(tool_name, source, name=name, group=g, default=default))
        return g

    def expose_text(self, tool_name, name=None, source="StyledText", font=True, color=True, size=True):
        self.expose(tool_name, source, name=name)
        if font:
            g = len(self.exposed) + 1
            self.exposed.append(instance(tool_name, "Font", name=(name + " Font") if name else None, group=g))
            self.exposed.append(instance(tool_name, "Style", group=g))
        if size:
            self.expose(tool_name, "Size", name=(name + " Size") if name else None)
        if color:
            self.expose_color(tool_name, "text", (name + " Color") if name else "Color")

    def expose_color(self, tool_name, kind, label):
        keys = ("Red1", "Green1", "Blue1") if kind == "text" else ("TopLeftRed", "TopLeftGreen", "TopLeftBlue")
        g = len(self.exposed) + 1
        for i, k in enumerate(keys):
            self.exposed.append(instance(tool_name, k, name=label if i == 0 else None, group=g))

    def expose_host(self, *names):
        for n in names:
            self.exposed.append(instance(self.h, n))

    # build ---------------------------------------------------------------------------
    def build(self, vis):
        h = self.h
        self.hidden("Vis", vis, 1)
        host_type = "Background" if self.shape else "TextPlus"
        tools = Ordered()
        tools[h] = tool(host_type, self.host_inputs, (0, 0), self.host_ui)
        if not self.shape:
            tools["Canvas"] = tool("Background", {"UseFrameFormatSettings": value(1), "TopLeftAlpha": value(0)}, (0, -66))
        tools.update(self.tools)
        prev = h if self.shape else "Canvas"
        x = self.x
        for i, (src, blend, clip) in enumerate(self.layers, start=1):
            name = f"Stack{i}"
            inputs = {"Background": link(prev), "Foreground": link(src), "PerformDepthMerge": value(0)}
            if blend is not None:
                inputs["Blend"] = _v(blend, 1)
            if clip is not None:
                inputs["EffectMask"] = link(clip, "Mask")
            tools[name] = tool("Merge", inputs, (x, 66))
            x += 110
            prev = name
        tools["Place"] = tool("Transform", {"Input": link(prev)}, (x, 66))
        self.exposed.append(instance("Place", "Center", name="Position"))
        self.exposed.append(instance("Place", "Size", name="Scale", default=1))
        self.expose_host("InFrames", "OutFrames")
        return macro(self.macro_name, self.exposed, "Place", tools)


def _v(v, default=0):
    """Plain value, or an expression when given a string."""
    if isinstance(v, str):
        return expr(v, default)
    if isinstance(v, tuple):
        v = list(v)
    return value(v)


# ======================================================================================
# Essential Typography
# ======================================================================================

def boxed_title():
    r = Rig("LL_BoxedTitle", 18, 12, host_inputs=text_inputs("MOTION GRAPHICS", 0.06, center=(0.5, 0.505)))
    h = r.h
    bw = r.control("BoxWidth", "Box Width", 0.42, 0, 1)
    bh = r.control("BoxHeight", "Box Height", 0.075, 0, 0.5)
    r.control("Line", "Line Width", 0.003, 0, 0.02)
    r.text("Caption", "WITHOUT HASSLE", 0.02, center=(0.5, 0.438), rgb=DARK)
    r.mask("BoxMask", "RectangleMask", (0.5, 0.5), f"{bw} * {h}.EaseIn * {h}.EaseOut", bh,
           Solid=0, BorderWidth=f"{h}.Line")
    r.fill("Box", ACCENT, "BoxMask")
    r.mask("TagMask", "RectangleMask", (0.5, 0.438), f"0.16 * {h}.Ease", 0.022, CornerRadius=0.2)
    r.fill("Tag", ACCENT, "TagMask")
    r.xf("TitleMove", h, center=f"Point(0.5, 0.5 - (1 - {h}.EaseIn) * 0.03 + (1 - {h}.EaseOut) * 0.03)", blur_motion=True)
    r.layer("Box")
    r.layer("Tag")
    r.layer("Caption", blend=f"{h}.Ease")
    r.layer("TitleMove", blend=f"{h}.Ease")
    r.expose_text(h)
    r.expose("Caption", "StyledText", name="Caption")
    r.expose_color("Box", "bg", "Accent Color")
    r.expose_host("BoxWidth", "BoxHeight", "Line")
    return r.build(f"{h}.Ease")


def tag_title():
    r = Rig("LL_TagTitle", 15, 12, host_inputs=text_inputs("MOTION GRAPHICS", 0.065, center=(0.5, 0.47)))
    h = r.h
    r.text("Caption", "WITHOUT HASSLE", 0.02, center=(0.5, 0.56), rgb=DARK)
    r.mask("TagMask", "RectangleMask", (0.5, 0.56), 0.15, 0.022, CornerRadius=0.2)
    r.fill("Tag", ACCENT, "TagMask")
    down = f"Point(0.5, 0.5 + (1 - {h}.EaseIn) * 0.05 - (1 - {h}.EaseOut) * 0.05)"
    r.xf("TagMove", "Tag", center=down)
    r.xf("CaptionMove", "Caption", center=down)
    r.xf("TitleMove", h, center=f"Point(0.5, 0.5 - (1 - {h}.EaseIn) * 0.05 + (1 - {h}.EaseOut) * 0.05)", blur_motion=True)
    r.layer("TagMove", blend=f"{h}.Ease")
    r.layer("CaptionMove", blend=f"{h}.Ease")
    r.layer("TitleMove", blend=f"{h}.Ease")
    r.expose_text(h)
    r.expose("Caption", "StyledText", name="Caption")
    r.expose_color("Tag", "bg", "Accent Color")
    return r.build(f"{h}.Ease")


def split_word():
    r = Rig("LL_SplitWord", 18, 12,
            host_inputs=dict(text_inputs("MISTER", 0.07, center=(0.49, 0.5), rgb=ACCENT),
                             HorizontalLeftCenterRight=value(1)))
    h = r.h
    r.text("Right", "HORSE", 0.07, center=(0.51, 0.5), left=True)
    r.mask("Divider", "RectangleMask", (0.5, 0.5), 0.003, f"0.06 * {h}.Ease")
    r.fill("Bar", WHITE, "Divider")
    r.mask("LeftClip", "RectangleMask", (0.249, 0.5), 0.5, 2)
    r.mask("RightClip", "RectangleMask", (0.751, 0.5), 0.5, 2)
    slide = f"((1 - {h}.EaseIn) + (1 - {h}.EaseOut)) * 0.12"
    r.xf("LeftMove", h, center=f"Point(0.5 + {slide}, 0.5)", blur_motion=True)
    r.xf("RightMove", "Right", center=f"Point(0.5 - {slide}, 0.5)", blur_motion=True)
    r.layer("Bar")
    r.layer("LeftMove", blend=f"{h}.Ease", clip="LeftClip")
    r.layer("RightMove", blend=f"{h}.Ease", clip="RightClip")
    r.expose_text(h, name="Left")
    r.expose_text("Right", name="Right")
    r.expose_color("Bar", "bg", "Divider Color")
    return r.build(f"{h}.Ease")


def underline():
    r = Rig("LL_Underline", 18, 12, host_inputs=text_inputs("POWERFUL WORKFLOW", 0.06, center=(0.5, 0.525)))
    h = r.h
    uw = r.control("UnderWidth", "Underline Width", 0.4, 0, 1)
    r.mask("LineMask", "RectangleMask", (0.5, 0.465), f"{uw} * {h}.EaseIn * {h}.EaseOut", 0.005, CornerRadius=1)
    r.fill("Line", ACCENT, "LineMask")
    r.xf("TitleMove", h, center=f"Point(0.5, 0.5 - (1 - {h}.EaseIn) * 0.04 - (1 - {h}.EaseOut) * 0.04)", blur_motion=True)
    r.layer("Line")
    r.layer("TitleMove", blend=f"{h}.Ease")
    r.expose_text(h)
    r.expose_color("Line", "bg", "Accent Color")
    r.expose_host("UnderWidth")
    return r.build(f"{h}.Ease")


# ======================================================================================
# Social
# ======================================================================================

BUTTON_TEXT = "\n".join([
    ":local start = 0",
    "if comp then start = comp.RenderStart end",
    "if time - start >= Title.ClickFrame then return tostring(Title.ClickedText.Value or \"\") end",
    "return tostring(Title.ButtonText.Value or \"\")",
])


def social_button(macro_name, label, clicked, rgb, clicked_rgb):
    r = Rig(macro_name, 12, 10, host_inputs=text_inputs("", 0.032, center=(0.5, 0.5)))
    h = r.h
    r.host_inputs["StyledText"] = expr(BUTTON_TEXT, "")
    r.text_control("ButtonText", "Button Text", label)
    r.text_control("ClickedText", "Clicked Text", clicked)
    r.control("ClickFrame", "Click at Frame", 30, 0, 240, integer=True)
    bw = r.control("BtnWidth", "Button Width", 0.2, 0.05, 0.6)
    bh = r.control("BtnHeight", "Button Height", 0.055, 0.02, 0.2)
    clickp = r.hidden("Clicked", clamp01(f"(time - comp.RenderStart - {h}.ClickFrame) / 3"), 0)
    r.hidden("Dip", f"1 - 0.08 * max(0, 1 - abs(time - comp.RenderStart - {h}.ClickFrame) / 4)")
    r.mask("BtnMask", "RectangleMask", (0.5, 0.5), bw, bh, CornerRadius=0.5)
    r.fill("Button", rgb, "BtnMask")
    r.fill("Pressed", clicked_rgb, "BtnMask")
    r.layer("Button")
    r.layer("Pressed", blend=clickp)
    r.layer(h)
    pop = r.pops()
    r.expose_host("ButtonText", "ClickedText", "ClickFrame")
    r.expose(h, "Font", group=True)
    r.exposed.append(instance(h, "Style", group=len(r.exposed)))
    r.expose(h, "Size", name="Text Size")
    r.expose_color(h, "text", "Text Color")
    r.expose_color("Button", "bg", "Button Color")
    r.expose_color("Pressed", "bg", "Clicked Color")
    r.expose_host("BtnWidth", "BtnHeight")
    m = r.build(pop)
    tools = m["Tools"][macro_name].body["Tools"]
    last = f"Stack{len(r.layers)}"
    tools["Bounce"] = tool("Transform", {"Input": link(last), "Size": expr(f"{pop} * {h}.Dip", 1),
                                         "MotionBlur": value(1), "Quality": value(5)}, (900, 132))
    tools["Place"] = tool("Transform", {"Input": link("Bounce")}, (1010, 132))
    return m


def subscribe():
    return social_button("LL_Subscribe", "SUBSCRIBE", "SUBSCRIBED", (0.86, 0.1, 0.1), (0.35, 0.35, 0.38))


def follow():
    return social_button("LL_Follow", "+  FOLLOW", "FOLLOWING", (0.1, 0.55, 0.98), (0.3, 0.3, 0.34))


def handle():
    r = Rig("LL_Handle", 16, 12,
            host_inputs=text_inputs("@yourname", 0.03, center=(0.435, 0.5), rgb=DARK, left=True))
    h = r.h
    pw = r.control("PillWidth", "Pill Width", 0.26, 0.05, 0.8)
    left = f"(0.5 - {pw} / 2)"
    r.mask("PillMask", "RectangleMask", f"Point({left} + {pw} * {h}.Ease / 2, 0.5)", f"{pw} * {h}.Ease", 0.05,
           CornerRadius=0.5)
    r.fill("Pill", WHITE, "PillMask")
    r.mask("DotMask", "EllipseMask", f"Point({left} + 0.028, 0.5)", f"0.034 * {h}.PopIn * {h}.PopOut", f"0.034 * {h}.PopIn * {h}.PopOut")
    r.fill("Dot", ACCENT, "DotMask")
    r.host_inputs["Center"] = expr(f"Point({left} + 0.055, 0.5)", [0.435, 0.5])
    r.pops()
    r.layer("Pill", blend=f"min({h}.Ease * 4, 1)")
    r.layer("Dot")
    r.layer(h, clip="PillMask")
    r.expose(h, "StyledText", name="Handle")
    g = len(r.exposed) + 1
    r.exposed.append(instance(h, "Font", group=g))
    r.exposed.append(instance(h, "Style", group=g))
    r.expose(h, "Size")
    r.expose_color(h, "text", "Text Color")
    r.expose_color("Pill", "bg", "Pill Color")
    r.expose_color("Dot", "bg", "Icon Color")
    r.expose_host("PillWidth")
    return r.build(f"{h}.Ease")


def chat_bubble():
    r = Rig("LL_ChatBubble", 12, 10, host_inputs=text_inputs("What's up?", 0.03, center=(0.5, 0.5), rgb=DARK, style="Regular"))
    h = r.h
    bw = r.control("BubbleWidth", "Bubble Width", 0.2, 0.05, 0.8)
    r.mask("BubbleMask", "RectangleMask", (0.5, 0.5), bw, 0.055, CornerRadius=0.5)
    r.fill("Bubble", WHITE, "BubbleMask")
    r.mask("TailMask", "RectangleMask", f"Point(0.5 - {bw} / 2 + 0.02, 0.468)", 0.018, 0.018, Angle=45)
    r.fill("Tail", WHITE, "TailMask")
    r.layer("Tail")
    r.layer("Bubble")
    r.layer(h)
    pop = r.pops()
    r.expose(h, "StyledText", name="Message")
    g = len(r.exposed) + 1
    r.exposed.append(instance(h, "Font", group=g))
    r.exposed.append(instance(h, "Style", group=g))
    r.expose(h, "Size")
    r.expose_color(h, "text", "Text Color")
    r.expose_color("Bubble", "bg", "Bubble Color")
    r.expose_host("BubbleWidth")
    m = r.build(pop)
    tools = m["Tools"]["LL_ChatBubble"].body["Tools"]
    tail = f"Point(0.5 - {h}.BubbleWidth / 2 + 0.02, 0.46)"
    tools["Bounce"] = tool("Transform", {"Input": link(f"Stack{len(r.layers)}"), "Size": expr(pop, 1),
                                         "Pivot": expr(tail, [0.42, 0.46]), "Center": expr(tail, [0.42, 0.46]),
                                         "MotionBlur": value(1), "Quality": value(5)}, (900, 132))
    tools["Place"] = tool("Transform", {"Input": link("Bounce")}, (1010, 132))
    return m


# ======================================================================================
# Timers & Counters
# ======================================================================================

COUNTER_TEXT = "\n".join([
    ":local start = 0",
    "if comp then start = comp.RenderStart end",
    "local p = (time - start - Title.CountDelay) / math.max(Title.CountFrames, 1)",
    "if p < 0 then p = 0 elseif p > 1 then p = 1 end",
    "p = 1 - (1 - p) ^ 3",
    "local v = Title.StartValue + (Title.EndValue - Title.StartValue) * p",
    "local d = math.floor(Title.Decimals + 0.5)",
    "local s = string.format(\"%.\" .. d .. \"f\", math.abs(v))",
    "if Title.Separator > 0.5 then",
    "  local int, frac = s:match(\"^(%d+)(.*)$\")",
    "  int = int:reverse():gsub(\"(%d%d%d)\", \"%1,\"):reverse()",
    "  if int:sub(1, 1) == \",\" then int = int:sub(2) end",
    "  s = int .. frac",
    "end",
    "if v < 0 then s = \"-\" .. s end",
    "return tostring(Title.Prefix.Value or \"\") .. s .. tostring(Title.Suffix.Value or \"\")",
])


def counter():
    r = Rig("LL_Counter", 10, 10, host_inputs=text_inputs("", 0.09, center=(0.5, 0.5)))
    h = r.h
    r.host_inputs["StyledText"] = expr(COUNTER_TEXT, "")
    r.control("StartValue", "Start Value", 0, 0, 100000)
    r.control("EndValue", "End Value", 38458, 0, 100000)
    r.control("Decimals", "Decimals", 0, 0, 4, integer=True)
    r.control("CountFrames", "Count Frames", 45, 1, 240, integer=True)
    r.control("CountDelay", "Count Delay", 0, 0, 120, integer=True)
    r.flag("Separator", "Thousands Separator", 1)
    r.text_control("Prefix", "Prefix", "$")
    r.text_control("Suffix", "Suffix", "")
    r.xf("Rise", h, center=f"Point(0.5, 0.5 - (1 - {h}.EaseIn) * 0.03)", blur_motion=True)
    r.layer("Rise", blend=f"{h}.Ease")
    r.expose_host("StartValue", "EndValue", "Decimals", "CountFrames", "CountDelay", "Separator", "Prefix", "Suffix")
    g = len(r.exposed) + 1
    r.exposed.append(instance(h, "Font", group=g))
    r.exposed.append(instance(h, "Style", group=g))
    r.expose(h, "Size")
    r.expose_color(h, "text", "Color")
    return r.build(f"{h}.Ease")


COUNTDOWN_TEXT = "\n".join([
    ":local start = 0",
    "if comp then start = comp.RenderStart end",
    "local remain = Title.StartSeconds - (time - start) / math.max(Title.FPS, 1)",
    "if remain < 0 then remain = 0 end",
    "local secs = math.ceil(remain - 0.000001)",
    "return string.format(\"%02d:%02d\", math.floor(secs / 60), secs % 60)",
])


def countdown():
    r = Rig("LL_Countdown", 10, 10, host_inputs=text_inputs("", 0.06, center=(0.5, 0.51)))
    h = r.h
    r.host_inputs["StyledText"] = expr(COUNTDOWN_TEXT, "")
    r.control("StartSeconds", "Start Seconds", 5, 1, 600, integer=True)
    r.control("FPS", "Frame Rate", 24, 1, 120)
    remain = r.hidden("Remain", clamp01(f"1 - (time - comp.RenderStart) / max({h}.StartSeconds * {h}.FPS, 1)"))
    r.mask("BoxMask", "RectangleMask", (0.5, 0.5), 0.19, 0.075, CornerRadius=0.25)
    r.fill("Box", DARK, "BoxMask", alpha=0.85)
    r.mask("TrackMask", "RectangleMask", (0.5, 0.455), 0.14, 0.004, CornerRadius=1)
    r.fill("Track", (0.35, 0.35, 0.38), "TrackMask")
    r.mask("BarMask", "RectangleMask", f"Point(0.43 + 0.14 * {remain} / 2, 0.455)", f"0.14 * {remain}", 0.004, CornerRadius=1)
    r.fill("Bar", ACCENT, "BarMask")
    r.layer("Box")
    r.layer("Track")
    r.layer("Bar")
    r.layer(h)
    pop = r.pops()
    r.expose_host("StartSeconds", "FPS")
    g = len(r.exposed) + 1
    r.exposed.append(instance(h, "Font", group=g))
    r.exposed.append(instance(h, "Style", group=g))
    r.expose(h, "Size")
    r.expose_color(h, "text", "Text Color")
    r.expose_color("Box", "bg", "Box Color")
    r.expose_color("Bar", "bg", "Accent Color")
    m = r.build(pop)
    tools = m["Tools"]["LL_Countdown"].body["Tools"]
    tools["Bounce"] = tool("Transform", {"Input": link(f"Stack{len(r.layers)}"), "Size": expr(pop, 1)}, (900, 132))
    tools["Place"] = tool("Transform", {"Input": link("Bounce")}, (1010, 132))
    return m


PERCENT_TEXT = "\n".join([
    ":local v = Title.Percent * Title.Count",
    "return string.format(\"%d%%\", math.floor(v + 0.5))",
])


def count_rig(r):
    h = r.h
    r.control("Percent", "Percent", 80, 0, 100)
    r.control("CountFrames", "Count Frames", 40, 1, 240, integer=True)
    r.hidden("CountP", clamp01(f"(time - comp.RenderStart) / max({h}.CountFrames, 1)"), 0)
    return r.hidden("Count", f"1 - (1 - {h}.CountP) * (1 - {h}.CountP) * (1 - {h}.CountP)", 0)


def progress_bar():
    r = Rig("LL_ProgressBar", 12, 12,
            host_inputs=text_inputs("1980 VOTES", 0.028, center=(0.25, 0.54), left=True))
    h = r.h
    bw = r.control("BarWidth", "Bar Width", 0.5, 0.05, 0.9)
    count = count_rig(r)
    r.host_inputs["Center"] = expr(f"Point(0.5 - {bw} / 2, 0.54)", [0.25, 0.54])
    r.add("PercentText", "TextPlus", dict(text_inputs("", 0.028, center=(0.75, 0.54)),
                                           StyledText=expr(PERCENT_TEXT, ""),
                                           HorizontalLeftCenterRight=value(1),
                                           Center=expr(f"Point(0.5 + {bw} / 2, 0.54)", [0.75, 0.54])))
    r.mask("TrackMask", "RectangleMask", (0.5, 0.48), bw, 0.018, CornerRadius=1)
    r.fill("Track", (0.3, 0.3, 0.34), "TrackMask", alpha=0.8)
    r.fill("Fill", ACCENT, "TrackMask")
    r.xf("FillMove", "Fill", center=f"Point(0.5 - {bw} * (1 - {h}.Percent / 100 * {count}), 0.5)")
    r.layer("Track", blend=f"{h}.Ease")
    r.layer("FillMove", blend=f"{h}.Ease", clip="TrackMask")
    r.layer(h, blend=f"{h}.Ease")
    r.layer("PercentText", blend=f"{h}.Ease")
    r.expose_host("Percent", "CountFrames")
    r.expose(h, "StyledText", name="Label")
    g = len(r.exposed) + 1
    r.exposed.append(instance(h, "Font", group=g))
    r.exposed.append(instance(h, "Style", group=g))
    r.expose_color(h, "text", "Text Color")
    r.expose_color("Fill", "bg", "Bar Color")
    r.expose_color("Track", "bg", "Track Color")
    r.expose_host("BarWidth")
    return r.build(f"{h}.Ease")


def bar_stat():
    r = Rig("LL_BarStat", 12, 12, host_inputs=text_inputs("YOUR TITLE", 0.03, center=(0.47, 0.43), left=True))
    h = r.h
    bh = r.control("BarHeight", "Bar Height", 0.16, 0.02, 0.5)
    count = count_rig(r)
    r.add("PercentText", "TextPlus", dict(text_inputs("", 0.09, center=(0.47, 0.52), left=True),
                                           StyledText=expr(PERCENT_TEXT, "")))
    r.mask("BarMask", "RectangleMask", (0.43, 0.5), 0.05, bh)
    r.fill("Bar", (0.1, 0.75, 0.9), "BarMask")
    r.xf("BarMove", "Bar", center=f"Point(0.5, 0.5 - {bh} * 1.7778 * (1 - {h}.Percent / 100 * {count}))")
    r.layer("BarMove", blend=f"{h}.Ease", clip="BarMask")
    r.layer("PercentText", blend=f"{h}.Ease")
    r.layer(h, blend=f"{h}.Ease")
    r.expose_host("Percent", "CountFrames")
    r.expose(h, "StyledText", name="Label")
    g = len(r.exposed) + 1
    r.exposed.append(instance(h, "Font", group=g))
    r.exposed.append(instance(h, "Style", group=g))
    r.expose_color(h, "text", "Text Color")
    r.expose_color("Bar", "bg", "Bar Color")
    r.expose_host("BarHeight")
    return r.build(f"{h}.Ease")


# ======================================================================================
# Cinematic
# ======================================================================================

def glow():
    r = Rig("LL_Glow", 24, 18,
            host_inputs=text_inputs("HORSE OF STEEL", 0.06, style="Regular", spacing=1.3))
    h = r.h
    size = r.control("GlowSize", "Glow Size", 10, 0, 50)
    amt = r.control("GlowAmount", "Glow Amount", 1.6, 0, 5)
    r.blur("GlowBlur", h, f"{size} * (1 + (1 - {h}.EaseIn) * 2)")
    r.gain("GlowGain", "GlowBlur", f"{amt} * (1 + (1 - {h}.EaseIn) * 1.5)")
    r.blur("Soften", h, f"(1 - {h}.Ease) * 6")
    r.layer("GlowGain", blend=f"{h}.Ease")
    r.layer("Soften", blend=f"{h}.Ease")
    r.expose_text(h)
    r.expose(h, "CharacterSpacing", name="Tracking")
    r.expose_host("GlowSize", "GlowAmount")
    return r.build(f"{h}.Ease")


def credits():
    r = Rig("LL_Credits", 30, 24,
            host_inputs=text_inputs("Mister Horse", 0.065, style="Regular", center=(0.5, 0.47)))
    h = r.h
    tr = r.control("Tracking", "Final Tracking", 1.05, 0.8, 2)
    r.host_inputs["CharacterSpacing"] = expr(f"{tr} + (1 - {h}.Ease) * 0.2", 1.05)
    r.text("Credit", "Created by", 0.024, style="Regular", center=(0.5, 0.54), rgb=(0.8, 0.8, 0.8))
    r.blur("Soften", h, f"(1 - {h}.Ease) * 5")
    r.layer("Credit", blend=f"{h}.EaseIn * {h}.EaseOut")
    r.layer("Soften", blend=f"{h}.Ease")
    m_vis = f"{h}.Ease"
    r.expose_text(h, name="Name")
    r.expose("Credit", "StyledText", name="Credit Line")
    r.expose_color("Credit", "text", "Credit Color")
    r.expose_host("Tracking")
    m = r.build(m_vis)
    tools = m["Tools"]["LL_Credits"].body["Tools"]
    drift = f"Point(0.5, 0.5 + 0.012 * (time - comp.RenderStart) / max(comp.RenderEnd - comp.RenderStart, 1))"
    tools["Drift"] = tool("Transform", {"Input": link(f"Stack{len(r.layers)}"), "Center": expr(drift, [0.5, 0.5])}, (900, 132))
    tools["Place"] = tool("Transform", {"Input": link("Drift")}, (1010, 132))
    return m


FLICKER_BLEND = "\n".join([
    ":local v = math.min(Title.RevealIn, Title.RevealOut)",
    "if v >= 1 then return 1 end",
    "if v <= 0 then return 0 end",
    "local n = math.sin(math.floor(time) * 12.9898 + Title.Seed * 78.233) * 43758.5453",
    "n = n - math.floor(n)",
    "if n < v then return 1 end",
    "return 0.06",
])


def flicker():
    r = Rig("LL_Flicker", 20, 14, host_inputs=text_inputs("PARADOX", 0.08, style="Regular", spacing=1.4))
    h = r.h
    r.control("Seed", "Random Seed", 1, 0, 100, integer=True)
    r.blur("GlowBlur", h, 12)
    r.gain("GlowGain", "GlowBlur", 1.4)
    r.layer("GlowGain", blend=FLICKER_BLEND)
    r.layer(h, blend=FLICKER_BLEND)
    r.expose_text(h)
    r.expose(h, "CharacterSpacing", name="Tracking")
    r.expose_host("Seed")
    return r.build(f"{h}.Ease")


def converge():
    r = Rig("LL_Converge", 24, 16, host_inputs=text_inputs("GRAND TITLES", 0.07, spacing=1.2))
    h = r.h
    ghost = f"4 * {h}.EaseIn * (1 - {h}.EaseIn) * 0.7"
    r.xf("GhostUp", h, center=f"Point(0.5, 0.5 + (1 - {h}.EaseIn) * 0.08)", blur_motion=True)
    r.xf("GhostDown", h, center=f"Point(0.5, 0.5 - (1 - {h}.EaseIn) * 0.08)", blur_motion=True)
    r.blur("Soften", h, f"(1 - {h}.Ease) * 8")
    r.mask("LineMask", "RectangleMask", (0.5, 0.5), f"0.6 * {h}.EaseIn", 0.002)
    r.fill("Line", ACCENT, "LineMask")
    r.layer("Line", blend=f"4 * {h}.EaseIn * (1 - {h}.EaseIn)")
    r.layer("GhostUp", blend=ghost)
    r.layer("GhostDown", blend=ghost)
    r.layer("Soften", blend=f"{h}.Ease")
    r.expose_text(h)
    r.expose(h, "CharacterSpacing", name="Tracking")
    r.expose_color("Line", "bg", "Accent Color")
    return r.build(f"{h}.Ease")


# ======================================================================================
# Shapes
# ======================================================================================

def ring_burst():
    r = Rig("LL_RingBurst", 0, 0, host="Canvas", shape=True)
    h = r.h
    r.burst(24)
    size = r.control("RingSize", "Ring Size", 0.3, 0, 1)
    thick = r.control("Thickness", "Thickness", 0.02, 0, 0.1)
    fade = f"min({h}.P * 8, 1) * (1 - {h}.P * {h}.P)"
    r.mask("RingMask", "EllipseMask", (0.5, 0.5), f"{size} * {h}.E", f"{size} * {h}.E",
           Solid=0, BorderWidth=f"{thick} * (1 - {h}.P)")
    r.fill("Ring", WHITE, "RingMask")
    r.layer("Ring", blend=fade)
    r.expose_color("Ring", "bg", "Color")
    r.expose_host("BurstFrames", "Delay", "RingSize", "Thickness")
    return r.build(fade)


def sparkle():
    r = Rig("LL_Sparkle", 0, 0, host="Canvas", shape=True)
    h = r.h
    r.burst(20)
    ln = r.control("SparkleSize", "Sparkle Size", 0.12, 0, 0.5)
    swell = r.hidden("Swell", f"sin({h}.P * pi)", 0)
    r.mask("HMask", "RectangleMask", (0.5, 0.5), f"{ln} * {swell}", 0.004, SoftEdge=0.004, CornerRadius=1)
    r.mask("VMask", "RectangleMask", (0.5, 0.5), 0.004, f"{ln} * {swell}", SoftEdge=0.004, CornerRadius=1)
    r.fill("HRay", WHITE, "HMask")
    r.fill("VRay", WHITE, "VMask")
    r.layer("HRay")
    r.layer("VRay")
    r.expose_color("HRay", "bg", "Color")
    r.expose_host("BurstFrames", "Delay", "SparkleSize")
    m = r.build(swell)
    tools = m["Tools"]["LL_Sparkle"].body["Tools"]
    tools["Spin"] = tool("Transform", {"Input": link("Stack2"), "Angle": expr(f"45 * {h}.P", 0)}, (900, 132))
    tools["GlowBlur"] = tool("Blur", {"Input": link("Spin"), "XBlurSize": value(8)}, (1010, 198))
    tools["Glow"] = tool("Merge", {"Background": link("Spin"), "Foreground": link("GlowBlur"),
                                   "PerformDepthMerge": value(0)}, (1010, 132))
    tools["Place"] = tool("Transform", {"Input": link("Glow")}, (1120, 132))
    # VRay follows the HRay colour so one colour control drives both
    vray = tools["VRay"].body["Inputs"]
    vray["TopLeftRed"] = expr("HRay.TopLeftRed", 1)
    vray["TopLeftGreen"] = expr("HRay.TopLeftGreen", 1)
    vray["TopLeftBlue"] = expr("HRay.TopLeftBlue", 1)
    return m


def speed_lines():
    r = Rig("LL_SpeedLines", 0, 0, host="Canvas", shape=True)
    h = r.h
    r.burst(18)
    ln = r.control("LineLength", "Line Length", 0.18, 0, 0.6)
    rows = [(0.42, 0), (0.47, 3), (0.53, 1), (0.58, 5)]
    for i, (y, lag) in enumerate(rows, start=1):
        p = r.hidden(f"P{i}", clamp01(f"(time - comp.RenderStart - {h}.Delay - {lag}) / max({h}.BurstFrames, 1)"), 0)
        r.mask(f"LineMask{i}", "RectangleMask", f"Point(0.3 + 0.4 * {p}, {y} + 0.1 * {p})",
               f"{ln} * sin({p} * pi)", 0.005, CornerRadius=1, Angle=14)
        rgb = ACCENT if i % 2 else WHITE
        r.fill(f"Line{i}", rgb, f"LineMask{i}")
        r.layer(f"Line{i}")
    r.expose_color("Line1", "bg", "Color A")
    r.expose_color("Line2", "bg", "Color B")
    r.expose_host("BurstFrames", "Delay", "LineLength")
    return r.build(f"max(sin({h}.P1 * pi), sin({h}.P4 * pi))")


def circle_pop():
    r = Rig("LL_CirclePop", 0, 0, host="Canvas", shape=True)
    h = r.h
    r.burst(24)
    size = r.control("CircleSize", "Circle Size", 0.12, 0, 0.6)
    grow = r.hidden("Grow", clamp01(f"{h}.P * 2"), 0)
    shrink = r.hidden("Shrink", clamp01(f"{h}.P * 2 - 1"), 0)
    dot = r.hidden("DotScale", f"max({back_out(grow)} * (1 - {shrink} * {shrink}), 0)", 0)
    r.mask("DotMask", "EllipseMask", (0.5, 0.5), f"{size} * {dot}", f"{size} * {dot}")
    r.fill("Dot", ACCENT, "DotMask")
    r.mask("RingMask", "EllipseMask", (0.5, 0.5), f"{size} * 2.2 * {h}.E", f"{size} * 2.2 * {h}.E",
           Solid=0, BorderWidth=f"0.012 * (1 - {h}.P)")
    r.fill("Ring", WHITE, "RingMask")
    ring_fade = f"min({h}.P * 6, 1) * (1 - {h}.P)"
    r.layer("Ring", blend=ring_fade)
    r.layer("Dot")
    r.expose_color("Dot", "bg", "Circle Color")
    r.expose_color("Ring", "bg", "Ring Color")
    r.expose_host("BurstFrames", "Delay", "CircleSize")
    return r.build(f"max({dot}, {ring_fade})")


LIBRARY = {
    "LL Boxed Title": boxed_title,
    "LL Tag Title": tag_title,
    "LL Split Word": split_word,
    "LL Underline": underline,
    "LL Subscribe": subscribe,
    "LL Follow": follow,
    "LL Handle": handle,
    "LL Chat Bubble": chat_bubble,
    "LL Counter": counter,
    "LL Countdown": countdown,
    "LL Progress Bar": progress_bar,
    "LL Bar Stat": bar_stat,
    "LL Glow": glow,
    "LL Credits": credits,
    "LL Flicker": flicker,
    "LL Converge": converge,
    "LL Ring Burst": ring_burst,
    "LL Sparkle": sparkle,
    "LL Speed Lines": speed_lines,
    "LL Circle Pop": circle_pop,
}
