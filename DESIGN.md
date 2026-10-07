---
name: Shoestring
description: Calm configuration and subscription allowance views for CLI agent work.
# REPO-INSPECTION: extracted from priv/static/assets/css/configuration.css.
colors:
  ink: "#172821"
  muted: "#52635b"
  accent: "#226448"
  ground: "#f5f7f4"
  paper: "#fff"
  line: "#d9e1d9"
  soft: "#eaf2e9"
  error: "#943a29"
typography:
  headline:
    fontFamily: "system-ui, sans-serif"
    fontSize: "28px"
    fontWeight: 600
    lineHeight: 1.25
    letterSpacing: "-.025em"
  title:
    fontFamily: "system-ui, sans-serif"
    fontSize: "19px"
    fontWeight: 600
    lineHeight: 1.4
    letterSpacing: "-.015em"
  subsection:
    fontFamily: "system-ui, sans-serif"
    fontSize: "14px"
    fontWeight: 600
    lineHeight: 1.5
  body:
    fontFamily: "system-ui, sans-serif"
    fontSize: "15px"
    lineHeight: 1.55
  label:
    fontFamily: "system-ui, sans-serif"
    fontSize: "14px"
    fontWeight: 500
    lineHeight: 1.55
  small:
    fontFamily: "system-ui, sans-serif"
    fontSize: "13px"
    lineHeight: 1.55
rounded:
  meter: "4px"
  navigation: "6px"
  control: "7px"
  panel: "12px"
spacing:
  compact: "8px"
  role-gap: "14px"
  row-gap: "16px"
  card-gap: "18px"
  field-gap: "20px"
  panel-inset: "24px"
  page-gutter: "28px"
  section: "32px"
components:
  button-primary:
    backgroundColor: "{colors.ink}"
    textColor: "{colors.paper}"
    rounded: "{rounded.control}"
    padding: "9px 14px"
  button-primary-hover:
    backgroundColor: "{colors.accent}"
    textColor: "{colors.paper}"
  button-secondary:
    backgroundColor: "{colors.paper}"
    textColor: "{colors.ink}"
    rounded: "{rounded.control}"
    padding: "9px 14px"
  button-secondary-hover:
    backgroundColor: "{colors.soft}"
  input:
    backgroundColor: "{colors.paper}"
    textColor: "{colors.ink}"
    rounded: "{rounded.control}"
    padding: "10px 12px"
  input-readonly:
    backgroundColor: "{colors.ground}"
  navigation-link:
    textColor: "{colors.muted}"
    rounded: "{rounded.navigation}"
    padding: "8px 13px"
  navigation-link-active:
    backgroundColor: "{colors.soft}"
    textColor: "{colors.ink}"
  panel:
    backgroundColor: "{colors.paper}"
    rounded: "{rounded.panel}"
    padding: "24px"
  meter:
    backgroundColor: "{colors.soft}"
    rounded: "{rounded.meter}"
    height: "8px"
  unknown:
    textColor: "{colors.muted}"
    rounded: "{rounded.navigation}"
    padding: "10px 12px"
---

# Design System: Shoestring

## Overview

**Creative North Star: "The Quiet Workbench"**

PROVISIONAL: The metaphor and descriptive palette names are documentation language inferred from the accepted direction; they are not additional user commitments. The quiet workbench describes a calm, plain interface with green accents, readable system type, and modest visual density. Familiar controls and visible labels carry the interaction.

REPO-INSPECTION: [PRODUCT.md](PRODUCT.md) establishes the minimal configuration and subscription allowance interface for CLI agent work. White panels and fields sit on a pale neutral ground, with fine rules and generous separation between groups. The visual system described here belongs to the Usage, Agents, and Settings product shell; legacy diagnostic views do not establish its tokens.

VERIFIED: All eight desktop/mobile final captures in `.impeccable/review/` were opened during this documentation pass. They show the implemented palette, single-column mobile forms, explicit unknown/stale readings, and a mobile save toast below the navigation. REPO-INSPECTION: Source values come from [configuration.css](priv/static/assets/css/configuration.css), the product LiveViews, and the product layout. UNVERIFIED: This document does not certify repository readiness, backend acceptance, provider access, or complete accessibility conformance. The full gate belongs to integration; I did not verify it in this documentation pass.

**Key Characteristics:**

- REPO-INSPECTION: Quiet green accents on pale ground and white surfaces.
- REPO-INSPECTION: Visible labels, compact bars, and restrained borders.
- REPO-INSPECTION: System typography and tabular allowance figures.
- REPO-INSPECTION: Responsive stacking without hidden primary navigation.

## Colors

PROVISIONAL: Descriptive names characterize the existing colors rather than creating a new palette. The frontmatter is normative; names below point to those token keys.

### Primary

- REPO-INSPECTION: **Forest Green** (`accent`) identifies links, history disclosure, observed meter fills, primary-button hover, caret, and keyboard focus.
- REPO-INSPECTION: **Deep Green Ink** (`ink`) supplies primary text and the resting primary-button fill.

### Neutral

- REPO-INSPECTION: **Sage Ground** (`ground`) is the page background and readonly-field surface.
- REPO-INSPECTION: **White Paper** (`paper`) is the panel and editable-field surface, and primary-button text.
- REPO-INSPECTION: **Slate Sage** (`muted`) carries supporting copy, metadata, and inactive navigation.
- REPO-INSPECTION: **Pale Sage** (`soft`) supports selected navigation, meter tracks, selection, secondary-button hover, and informational feedback.
- REPO-INSPECTION: **Soft Green Rule** (`line`) delineates panels, fields, role rows, and observation timestamps.

### Status

- REPO-INSPECTION: **Rust Warning** (`error`) identifies stale notices and form errors. It is a semantic status color rather than a second brand accent.

REPO-INSPECTION — **The Explicit State Rule.** Pair status color with plain language. Unknown readings have their own dashed container; missing observations remain gaps rather than filled bars.

## Typography

REPO-INSPECTION: **Headline and Body Font:** system-ui with sans-serif fallback. No external font is required. CLI names use the existing code element's inherited monospace treatment; no custom mono family is defined by the product stylesheet.

PROVISIONAL: The type character is practical and restrained. Weight and spacing supply hierarchy without a separate display face.

### Hierarchy

- REPO-INSPECTION: **Headline** uses the `headline` role for page headings.
- REPO-INSPECTION: **Title** uses the `title` role for panel and section headings.
- REPO-INSPECTION: **Subsection** uses the `subsection` role for allowance-window headings.
- REPO-INSPECTION: **Body** uses the `body` role; paragraphs stop at (72ch).
- REPO-INSPECTION: **Label** uses the `label` role; explicit dark label styling also overrides the underlying form component's label color.
- REPO-INSPECTION: **Small** uses the `small` role for observation metadata and footnotes. History dates alone use (11px).
- REPO-INSPECTION: The wordmark uses (18px), weight (650), and letter-spacing (-.02em). Numerical allowance values and observation timestamps use tabular numerals.

## Layout

REPO-INSPECTION: The header and main content share a centered container with maximum width (1128px), including their horizontal padding. Desktop header padding is (24px 28px); main padding is (36px 28px 48px). Cards use two equal columns and the `card-gap` spacing. Forms stop at (820px), with paired fields using the `field-gap` spacing. Team editing uses four columns (`1fr 1fr 1.25fr auto`), with a control column for removal.

REPO-INSPECTION: At widths of (700px) or less, navigation occupies a separate full-width row, cards and form fields become one column, and team controls stack. The header uses (20px) padding and a (14px) gap; main padding becomes (28px 20px 40px). Panel padding becomes (20px). Inputs use (16px) type at this breakpoint. Save feedback is fixed (20px) above the bottom, with (20px) side insets. Page headings wrap their action onto a new row as needed.

## Elevation & Depth

REPO-INSPECTION: Product panels and controls have no custom shadows. White surfaces, pale ground, and thin borders convey grouping. The shared flash component retains its underlying alert styling; the product stylesheet overrides its colors and mobile placement rather than defining a new shadow vocabulary. No product motion or transition tokens are defined.

REPO-INSPECTION — **The Quiet Surface Rule.** Preserve the flat resting treatment for product panels and controls; use the existing tonal and border changes to indicate state.

## Shapes

REPO-INSPECTION: The four radius roles in frontmatter distinguish compact tracks, navigation/unknown states, controls, and panels. Outlines and borders use (1px) rules, while keyboard focus uses a (2px) accent outline with (3px) offset. Controls maintain a minimum height of (44px). Meter tracks clip their fill; scope labels and model identifiers may wrap anywhere to stay within their containers.

## Components

### Buttons

PROVISIONAL: Plain and confident, with visual weight reserved for the primary action.

REPO-INSPECTION: Primary buttons use `button-primary` at rest and `button-primary-hover` on hover. Secondary buttons use the white bordered variant and pale hover fill. Both share the control radius, minimum height, and inherited body font with weight (500). Disabled buttons use opacity (.55) and the default cursor. Links keep text treatment unless acting as buttons. All product controls use the common visible focus outline; no custom active animation is defined.

### Cards / Containers

REPO-INSPECTION: Panels use the `panel` component token with a thin rule border and the flat treatment from Elevation & Depth. Titles and metadata share a baseline-aligned row. Agent role summaries use horizontal rules and right-aligned provider/model text. Unknown allowance containers use a dashed border, with written state and reason rather than a meter.

### Inputs / Fields

REPO-INSPECTION: Editable fields use the `input` component token and the common focus outline. Readonly text fields use `input-readonly`; selects preserve their native affordance. Textareas resize vertically. Labels remain outside the field, and placeholders use muted text. Form errors use a bordered rust container and plain error text, with reload actions when present; the product stylesheet does not define a separate disabled-field treatment.

### Navigation

REPO-INSPECTION: Three text links remain visible in the header. Default links use `navigation-link`; the selected link uses `navigation-link-active`, weight (600), and `aria-current="page"`. Hover uses the pale surface. At the mobile breakpoint, links move below the brand while preserving their order and labels.

### Allowance Windows and History

REPO-INSPECTION: Observed allowance windows combine a title, right-aligned used value, `meter` track, remaining value, and reset timestamp. The observation timestamp is separated by a rule. Stale readings keep their explanatory notice visible alongside saved observations. History sits behind native details/summary disclosure; its columns use an (84px) plot area, (16px) bars, and visible date labels. Missing days show a dash. These patterns describe saved observations rather than live provider access.

## Do's and Don'ts

### Do:

- Do use the existing system font, quiet palette, and visible field labels.
- Do retain the common accent outline for keyboard focus.
- Do stack paired fields and panels at the existing mobile breakpoint.
- Do pair allowance bars with values, units, and observation context.
- Do preserve readable unknown, stale, and missing-data states.

### Don't:

- Don't replace missing allowance data with an invented meter fill.
- Don't use status color as the only explanation of a state.
- Don't add external font or image dependencies to reproduce this system.
- Don't treat provisional descriptive names as new brand commitments.

REPO-INSPECTION: These guardrails record the incumbent implementation and accepted product direction. The sidecar's tonal ramps are SCHEMA-ONLY preview extensions, not implemented palette tokens.
