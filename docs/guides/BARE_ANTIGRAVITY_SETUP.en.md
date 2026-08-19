# 🚀 Deploying Agentic Pipeline on Bare Antigravity in 3 Steps

> **Step-by-Step Guide for a Clean 2-Minute Bootstrap**  
> Setup Time: **2 minutes** | Requirements: Antigravity IDE, PowerShell 7+, Node.js 18+, Git

---

## ⚡ Express Installation (3 Commands)

### Step 1. Clone the Framework Repository
Open PowerShell or your terminal and clone the repository:

```powershell
cd "$env:USERPROFILE\Documents\antigravity"
git clone https://github.com/0xAgentive/agentic-pipeline.git
cd agentic-pipeline
```

---

### Step 2. Install Global Antigravity Skills (1 Click)
Run the automated global installer:

```powershell
& pwsh -NoProfile -ExecutionPolicy Bypass -File "./scripts/windows/Install-GlobalSkills.ps1"
```

*What happens automatically:*  
The installer copies all 6 global pipeline skills (`agentic-project-scaffold`, `companion-project-context-pack`, `local-artifact-delivery`, `quota-safe-continuity`, `stitch-design-sync`, `mcp-tooling-discipline`) into your global Antigravity config directory (`~/.gemini/config/skills/`). They immediately become active across all projects and chat windows!

---

### Step 3. Bootstrap your First Project!
Open Antigravity, open a new chat with the agent, and type:

```text
/new-project MyAwesomeProject
```

*Done!* In ~10 seconds, the agent will:
1. Initialize the repository `C:\Users\<You>\Documents\antigravity\MyAwesomeProject`;
2. Deploy v1.2.27 governance, safety rules, and Stage Firewall;
3. Register the project in Companion Action Bridge;
4. **Generate a ready-to-use `<PROJECT>_COMPREHENSIVE_COMPANION_PACK.zip` to upload to ChatGPT / Claude.**

---

## 🔄 How to Onboard an EXISTING Repository (Adopt Mode)

If you already have an existing project (Python, React, Rust, Go, C#) and want to onboard it into Handoff-Driven Development:

Inside Antigravity chat, simply type:
```text
/adopt-project C:\path\to\your\existing-repo
```

The pipeline cleanly adds `.agents/` and `.agy/` control planes **without modifying a single line of your existing source code**, and automatically packages a context ZIP for ChatGPT.

---

## 🧭 Handoff-Driven Development Workflow

```text
1. Export Pure Architecture Context:  /companion-pack
2. Attach Context ZIP to ChatGPT:     Companion plans and exports an Action Packet
3. Download JSON from Browser:        Action Bridge captures it into project in ~250ms
4. Trigger Antigravity:               /nextphase (or /nextphase /goal)
5. Get Clean Results:                 4-section summary report + LATEST_CONTEXT.zip
```

---

*See full command reference: [Atlas of Skills & Commands](../reference/COMMANDS_AND_SKILLS_DIRECTORY.md)*
