---
name: matcha-lua
description: Use this skill for writing, generating, or debugging Lua scripts specifically for Roblox Matcha external executor LuaVM. Triggers on requests to create scripts for Matcha, Roblox external cheating scripts using Matcha API, based on the provided documentation. Always reference the official Matcha docs and example scripts.
---

# Matcha Lua Skill

This skill equips the agent with specialized knowledge for generating accurate Lua scripts compatible with the Matcha external Roblox executor.

## Core Principles

- **Always base scripts on official docs**: Use https://doc.wabisabi.mom/matcha/ as primary reference for API, globals, classes, datatypes, memory, etc.
- **UI Integration**: Use the UI library from MatchaScripts repo for menus, tabs, widgets (toggles, sliders, keybinds, etc.).
- **External Nature**: Remember Matcha emulates Roblox API externally — no internal hooks. Scripts rely on memory reads/writes, Drawing API, etc.
- **Safety**: Generate safe, functional code. Avoid promoting harmful use.

## Key References

Read these for details:
- Main docs: https://doc.wabisabi.mom/matcha/
- Examples: https://github.com/cconstellation/MatchaScripts

## When Generating Scripts

1. **Structure**:
   - Start with `UI.AddTab` for menu.
   - Use sections + widgets for configuration.
   - Main loop with `wait()` / `task.wait()`.
   - Handle game-specific logic.

2. **Common Patterns**:
   - ESP via Drawing API.
   - Aimbot with memory functions.
   - Use globals like `getgc`, `memory_read/write`.
   - Console logging.

3. **Best Practices**:
   - Modular code, comments with doc references.
   - Proper widget callbacks and state management.

4. **Documentation**:
   - First read the docs, then code. API in Matcha is different from normal lua functions.
