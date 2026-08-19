---
name: stitch-design-sync
description: >-
  Extracts, packages, and synchronizes a frontend application's design system and screens
  into Google Stitch via Stitch MCP. Use when the user asks to export, transfer, or sync
  current UI designs, screens, or design tokens to Google Stitch, or when invoked via
  slash command `/stitch-design-sync` or `/stitch-sync`.
---

# Stitch Design System & Screen Sync Workflow

This skill automates the extraction of a production UI codebase (React, Vue, HTML/CSS, Tailwind) and synchronizes it with Google Stitch via the Stitch MCP Server (`stitch`).

## When to Activate
- When the user types `/stitch-design-sync`, `/stitch-sync`, `/stitch`, or asks to "перенести дизайн в стич", "синхронизировать со stitch", "экспортировать дизайн в Google Stitch".
- When transferring updated design tokens, color schemes, or component layouts from a local web application to an interactive Stitch canvas for stakeholders.

---

## Step-by-Step Procedure

### 1. Discovery & Design Token Extraction (`DESIGN.md`)
1. Inspect the local codebase:
   - Scan `index.css` / `tailwind.config.js` for colors, surfaces, border radiuses, and blur tokens.
   - Scan primary pages/components to extract layout hierarchy and typography (e.g. Roboto, Inter).
2. Synthesize a unified `DESIGN.md` in YAML frontmatter format:
   - Root colors (canvas, surface, surface-glass, borders, primary/secondary/tertiary accents).
   - Typography scales (display-lg, headline-lg, body-lg, mono-data).
   - Brand guidelines (e.g., *Glassmorphic Modernism*, *Pure Black #000000*, *Zero Subjective Scoring*).

### 2. Project Ingestion via Stitch MCP
1. **Create/Verify Project:**
   ```text
   Tool: call_mcp_tool(ServerName: 'stitch', ToolName: 'create_project', Arguments: { title: '<Project Title> v2' })
   ```
2. **Encode and Upload DESIGN.md:**
   - Base64 encode the `DESIGN.md` content (UTF-8).
   - Call `upload_design_md`:
     ```text
     Tool: call_mcp_tool(ServerName: 'stitch', ToolName: 'upload_design_md', Arguments: {
       projectId: '<projectId>',
       designMdBase64: '<base64_string>'
     })
     ```
3. **Bind Design System Asset:**
   - Immediately call `create_design_system_from_design_md`:
     ```text
     Tool: call_mcp_tool(ServerName: 'stitch', ToolName: 'create_design_system_from_design_md', Arguments: {
       projectId: '<projectId>',
       deviceType: 'DESKTOP',
       selectedScreenInstance: { id: '<screenInstanceId>', sourceScreen: '<sourceScreen>' }
     })
     ```

### 3. Screen Synthesis (`generate_screen_from_text`)
For each core route in the application:
1. Formulate a structured blueprint prompt detailing:
   - Fixed Sidebar (width, background blur, branding, active state indicator).
   - Header (title, subtitle, calendar pills, language toggles, action buttons).
   - Content Grid & Cards (exact metrics, charts, tables, button styles).
2. Call `generate_screen_from_text` with:
   - `projectId`: `<projectId>`
   - `designSystem`: `assets/<assetId>`
   - `deviceType`: `"DESKTOP"`
   - `modelId`: `"GEMINI_3_1_PRO"`

### 4. Production Fidelity Calibration Loop (`edit_screens`)
If any generated screen exhibits visual drift (e.g. serif fonts, oversized banners, misaligned cards):
1. Issue a targeted `edit_screens` request containing:
   - **Negative Constraints:** *"Completely remove all serif fonts. No serif logo, no serif headings, no serif buttons."*
   - **Positive Constraints:** Specify exact Tailwind classes (e.g. `bg-white/[0.03] backdrop-blur-xl border border-white/[0.08] rounded-3xl`).
   - **Data Typography:** *"Use Roboto Mono for all timestamps, row counts, and telemetry numbers."*

### 5. Verification & Output Reporting
1. Call `list_screens` to verify all screens are generated and healthy.
2. Report the Stitch project resource name (`projects/<id>`) and direct screen IDs in the final compact output block.
