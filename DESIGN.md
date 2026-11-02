---
name: brain
description: A night-observatory visual system for a git-backed memory that coding agents read before they grep.
colors:
  void: "#070807"
  void-raised: "#0c0e0c"
  void-panel: "#121512"
  hairline: "#1e231f"
  hairline-strong: "#2a312b"
  signal-green: "#40d987"
  signal-green-deep: "#1f7a4c"
  signal-green-glow: "rgba(64,217,135,.22)"
  alert-orange: "#ff8f2a"
  alert-orange-deep: "#8a4a12"
  alert-orange-glow: "rgba(255,143,42,.22)"
  ink-on-green: "#06130b"
  text: "#e9ece6"
  text-muted: "#b9c1b8"
  text-faint: "#7f8a7f"
  bright: "#f3f5f0"
typography:
  display:
    fontFamily: "Syne, ui-sans-serif, system-ui, sans-serif"
    fontSize: "clamp(42px, 7.4vw, 96px)"
    fontWeight: 800
    lineHeight: 1.05
    letterSpacing: "-0.035em"
  headline:
    fontFamily: "Syne, ui-sans-serif, system-ui, sans-serif"
    fontSize: "clamp(30px, 4.2vw, 48px)"
    fontWeight: 700
    lineHeight: 1.05
    letterSpacing: "-0.02em"
  title:
    fontFamily: "Syne, ui-sans-serif, system-ui, sans-serif"
    fontSize: "clamp(20px, 2vw, 24px)"
    fontWeight: 700
    lineHeight: 1.05
    letterSpacing: "-0.01em"
  quote:
    fontFamily: "Syne, ui-sans-serif, system-ui, sans-serif"
    fontSize: "clamp(22px, 2.6vw, 30px)"
    fontWeight: 500
    lineHeight: 1.25
    letterSpacing: "-0.015em"
  lede:
    fontFamily: "Instrument Sans, ui-sans-serif, system-ui, sans-serif"
    fontSize: "clamp(18px, 1.5vw, 21px)"
    fontWeight: 400
    lineHeight: 1.6
  body:
    fontFamily: "Instrument Sans, ui-sans-serif, system-ui, sans-serif"
    fontSize: "17px"
    fontWeight: 400
    lineHeight: 1.6
  body-small:
    fontFamily: "Instrument Sans, ui-sans-serif, system-ui, sans-serif"
    fontSize: "15.5px"
    fontWeight: 400
    lineHeight: 1.6
  label:
    fontFamily: "JetBrains Mono, ui-monospace, SFMono-Regular, Menlo, monospace"
    fontSize: "12px"
    fontWeight: 400
    lineHeight: 1.6
  code:
    fontFamily: "JetBrains Mono, ui-monospace, SFMono-Regular, Menlo, monospace"
    fontSize: "13.5px"
    fontWeight: 400
    lineHeight: 1.7
rounded:
  xs: "3px"
  sm: "5px"
  md: "10px"
  lg: "12px"
  xl: "14px"
  pill: "999px"
spacing:
  xs: "4px"
  sm: "8px"
  md: "16px"
  lg: "28px"
  xl: "48px"
  gutter: "clamp(16px, 4vw, 56px)"
  section: "clamp(72px, 10vw, 140px)"
components:
  button-primary:
    backgroundColor: "{colors.signal-green}"
    textColor: "{colors.ink-on-green}"
    typography: "{typography.title}"
    rounded: "{rounded.pill}"
    padding: "13px 20px"
  button-primary-hover:
    backgroundColor: "#5ae79b"
    textColor: "{colors.ink-on-green}"
  button-ghost:
    backgroundColor: "rgba(12,14,12,.7)"
    textColor: "{colors.text}"
    rounded: "{rounded.pill}"
    padding: "13px 20px"
  button-ghost-hover:
    backgroundColor: "rgba(18,22,18,.9)"
    textColor: "{colors.text}"
  tab-selected:
    backgroundColor: "{colors.text}"
    textColor: "{colors.ink-on-green}"
    rounded: "{rounded.pill}"
    padding: "9px 16px"
  tab:
    backgroundColor: "transparent"
    textColor: "{colors.text-muted}"
    rounded: "{rounded.pill}"
    padding: "9px 16px"
  code-block:
    backgroundColor: "{colors.void-raised}"
    textColor: "{colors.text-muted}"
    typography: "{typography.code}"
    rounded: "{rounded.md}"
    padding: "16px 18px"
  code-inline:
    backgroundColor: "{colors.void-panel}"
    textColor: "{colors.text}"
    rounded: "{rounded.sm}"
    padding: "0.1em 0.4em"
  card-panel:
    backgroundColor: "{colors.void-raised}"
    textColor: "{colors.text-muted}"
    rounded: "{rounded.xl}"
    padding: "28px 26px 30px"
  figure-caption:
    backgroundColor: "{colors.void-raised}"
    textColor: "{colors.text-faint}"
    padding: "10px 14px"
---

# Design System: brain

## Overview

**Creative North Star: "The Night Observatory"**

A dark instrument room where a living graph is the only light. The field is near-black and stays
that way; the graph's green nodes are the signal, orange is the alert, and everything else is
hairlines and readouts. The page feels calm and precise, with a hint of cinema from the
canvas-drawn graph in the hero, but nothing glows at rest and nothing competes with the data.

Density is comfortable, not dashboard-dense. Sections breathe with generous vertical padding;
inside them, information sits in hairline-bounded grids (three layers, five stages, two-column
rules) that read like labelled instrument panels. Depth comes from stepping the black up a tone and
drawing a 1px line, never from shadows, except under the two kinds of "media": screenshots and the
transcript card, which are allowed one deep, low, dark shadow so they sit on the bench.

Type does the persuading. Syne, heavy and tightly tracked, carries every heading and button;
Instrument Sans carries the reading; JetBrains Mono carries anything the machine said or the user
will type. Confirmed anti-references: no glassmorphism cards, no gradient text, no neon glow at
rest, no stock illustration.

**Key Characteristics:**
- Near-black tonal field in three steps (`void`, `void-raised`, `void-panel`) with 1px hairlines.
- One signal colour (green) for links, primary action, live dots and "good" readouts; one alert
  colour (orange) for drift, failure and the third step of any sequence.
- Syne display at 700–800 with negative tracking; mono for every machine string.
- Pill geometry for interactive controls, 10–14px radii for panels, hairline borders everywhere.
- Flat by default; shadows only under media.
- Motion is restrained: 200ms colour/border transitions, 250ms lift on buttons, a living canvas in
  the hero, everything off under reduced-motion.

## Colors

A black field lit by two signals: the palette is three blacks, two hairlines, four greys, green and
orange.

### Primary
- **Signal Green** (`signal-green`): links, the primary button fill, host dots, sequence step 2,
  "good" readouts in transcripts and verdicts, focus rings, text selection. Rare on purpose.
- **Signal Green Deep** (`signal-green-deep`): the mid-point of the loop's connecting line; never
  a fill behind text.
- **Signal Green Glow** (`signal-green-glow`): canvas node halos only.
- **Ink on Green** (`ink-on-green`): the only text colour permitted on a green or white fill.

### Secondary
- **Alert Orange** (`alert-orange`): drift, failure, "before" states in transcripts, sequence step 3,
  the orange node family in the graph. Never a fill behind body text.
- **Alert Orange Deep** / **Alert Orange Glow**: canvas-only companions to the above.

### Neutral
- **Void** (`void`): page background, the `.stage` dot interior, nav scrim base.
- **Void Raised** (`void-raised`): code blocks, panels, transcript, captions, tab rails.
- **Void Panel** (`void-panel`): inline code, hover fill for nav links and unselected tabs, arrow chips.
- **Hairline** (`hairline`): every section divider, panel border and rule divider.
- **Hairline Strong** (`hairline-strong`): button borders, dashed dividers, scrollbar thumb, counter rings.
- **Text** (`text`): headings and emphasised copy.
- **Text Muted** (`text-muted`): body paragraphs inside panels, lede, code block default.
- **Text Faint** (`text-faint`): labels, captions, step numbers, mono comments.
- **Bright** (`bright`): the user's voice in transcripts and mono output readouts.

### Named Rules
**The Two Signals Rule.** Green means live or good; orange means drift or alert. No third accent,
and neither colour appears as a large fill except the single primary button.

**The Ink Rule.** Text on a green or white fill is always `ink-on-green`, never black or grey.

## Typography

**Display Font:** Syne (with system sans fallback)
**Body Font:** Instrument Sans (with system sans fallback)
**Label/Mono Font:** JetBrains Mono (with system mono fallback)

**Character:** Syne is geometric and slightly odd at 800, which keeps the dark page from reading as
generic SaaS; Instrument Sans is neutral enough to disappear under it. Mono is the third voice and
it is literal: anything the machine said, or the user will type, is mono.

### Hierarchy
- **Display** (800, clamp 42–96px, 1.05, -0.035em): the hero headline only, max 11ch; one word may
  take Signal Green via `<em>`.
- **Headline** (700, clamp 30–48px, 1.05, -0.02em): section headings, balanced wrap.
- **Title** (700, clamp 20–24px, 1.05): panel and rule headings; buttons and tabs use the same face
  at 14–15px.
- **Quote** (500, clamp 22–30px, 1.25, -0.015em): the one pull-quote in the problem section.
- **Lede** (400, clamp 18–21px, 1.6): the paragraph under each headline, max 62ch.
- **Body** (400, 17px, 1.6) and **Body Small** (400, 15.5px): paragraphs; inside panels and rules
  always the small size in Text Muted.
- **Label** (mono, 12–13px): step numbers, verdicts, captions, mono output.
- **Code** (mono, 13.5px, 1.7): transcript and code blocks.

### Named Rules
**The Machine Voice Rule.** Commands, file names, skill names and transcript lines are JetBrains
Mono, never styled sans.

**The One Display Rule.** Display weight 800 appears once per page, in the hero.

## Layout

A single centred column (`max` 1180px) with a fluid gutter (`gutter`, 16–56px). Sections stack with
fluid vertical padding (`section`, 72–140px) and a hairline between neighbours; the hero is
full-viewport (100svh, 92svh under 900px) with content anchored to the bottom edge over a canvas.
Inside sections, content uses hairline-bounded grids: a 3-column layer strip, a 5-column loop with a
connecting line, two-column rule rows, a 1.05/.95 split for problem and transcript, a .9/1.1 split
for skills and screenshots. Breakpoints are per-component rather than global: 1000px (loop to two
columns), 900px (hero caption hidden, tend stacks), 860px (split, layers and install panels stack),
720px (nav links hidden), 700px (rules stack), 560px (loop single column), 480px (skills stack).
Spacing rhythm is 4/8/16/28/48 with section-level values fluid.

## Elevation & Depth

Tonal layering, not shadows. Depth is a step from Void to Void Raised to Void Panel plus a 1px
Hairline; hover states step one tone up. Two exceptions carry a single deep, low shadow so they
read as physical objects on the bench: screenshot figures and the transcript card.

### Shadow Vocabulary
- **Bench media** (`box-shadow: 0 30px 60px -40px rgba(0,0,0,1)`): screenshot figures.
- **Bench card** (`box-shadow: 0 20px 50px -30px rgba(0,0,0,.9)`): the transcript card.

### Named Rules
**The Flat Bench Rule.** Surfaces are flat and hairlined at rest. Shadows exist only under media and
the transcript; buttons, panels and tabs never cast one.

## Shapes

Two geometries. Interactive controls are pills (`pill`): buttons, nav link rail, tab rail, tabs.
Containers are softly rounded: inline code 5px, code blocks 10px, transcript and figures 12px, the
layer strip 14px. Dots are circles (6px host dots, 8px step dots, 11px stage markers with a 2px green
ring, 24px counter rings). Borders are always 1px, solid Hairline for containers and Hairline Strong
for controls; dashed Hairline Strong marks an internal divider. Focus is a 2px green outline offset
3px with a 3px radius.

## Components

### Buttons
- **Shape:** pill (999px), 1px border.
- **Primary:** Signal Green fill, Ink on Green text, Syne 700 at 15px, padding 13px 20px; hover
  lightens the fill to `#5ae79b`.
- **Ghost:** translucent Void Raised fill with 8px backdrop blur, Text colour, Hairline Strong
  border; hover turns the border green and lifts 1px.
- **Hover / Focus:** border-color and background 200ms, transform 250ms on a `cubic-bezier(.2,.8,.2,1)`;
  focus-visible uses the global green outline. Inline 16px stroke icons at 2px.

### Tabs
- **Style:** a pill rail (Void Raised, Hairline border, 4px padding) holding pill buttons in Syne
  700 at 14px, Text Muted.
- **State:** selected is a Text (off-white) fill with Ink on Green text; unselected hover steps to
  Void Panel.

### Cards / Containers
- **Corner Style:** 10px (code), 12px (transcript, figures), 14px (layer strip).
- **Background:** Void Raised; figures sit on pure black behind the image.
- **Shadow Strategy:** none, except bench media and the transcript (see Elevation).
- **Border:** 1px Hairline; sibling panels share one hairline rather than doubling it.
- **Internal Padding:** 28px 26px 30px for layers, 16px 18px for code, 20px 22px for the transcript.

### Navigation
- Fixed, transparent bar; brand is Syne 800 at 18px with a 26px mark. Links sit in a translucent
  pill rail with 10px blur; links are 14px/500 Text Muted, hover to Text on Void Panel. The rail is
  hidden under 720px. Footer nav is static, 20px gaps, Text Muted links.

### Code and Transcripts
- Code blocks: Void Raised, Hairline border, 10px radius, mono 13.5px at 1.7, Text Muted base with
  four token colours (comment faint, green, orange, bright white).
- Transcript: same surface at 12px radius with the bench-card shadow; speaker in Bright, machine in
  Text Faint, failures in Alert Orange, successes in Signal Green, dashed hairline turns.

### Sequences (signature)
- Three-layer strip: a hairlined row of panels, each opened by a mono step label with a coloured
  dot (white, green, orange in order) and joined by 26px circular arrow chips straddling the border.
- Five-stage loop: a 1px line fading from Hairline Strong through Signal Green Deep, with each stage
  pinned by an 11px ring dot; stage titles 19px, verdict lines in mono green.
- Rule rows: two-column baseline-aligned rows separated by hairlines, heading left, explanation right.

### Figures
- Screenshot figures: 12px radius, Hairline border, black backing, bench-media shadow; caption bar
  in Void Raised with a top hairline, 13px Text Faint with a Text Muted lead.

## Do's and Don'ts

### Do:
- **Do** keep the page background at Void and build depth with Void Raised and Void Panel plus 1px
  hairlines.
- **Do** reserve Signal Green for links, the primary action, live dots and good states, and Alert
  Orange for drift and failure.
- **Do** set every command, path and transcript line in JetBrains Mono.
- **Do** use pills for interactive controls and 10–14px radii for containers.
- **Do** honour `prefers-reduced-motion` by removing all animation and transition.

### Don't:
- **Don't** add shadows to buttons, panels or tabs; only media and the transcript cast one.
- **Don't** introduce a third accent, gradient text, or glow at rest.
- **Don't** put black or grey text on a green or white fill; use Ink on Green.
- **Don't** use Display weight 800 anywhere but the hero headline.
- **Don't** replace the hairline grid with floating glass cards.
