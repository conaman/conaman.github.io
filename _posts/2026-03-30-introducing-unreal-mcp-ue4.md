---
layout: post
title: "Introducing unreal-mcp-ue4"
date: 2026-03-30 10:40:00 +0900
tags: [UnrealEngine, UE4, MCP, Tooling]
---

`unreal-mcp-ue4` is a UE4.27.2-focused MCP server for Unreal Engine built around Unreal Python Remote Execution.

The project started from the core idea and early workflow shape of `runreal/unreal-mcp`, but it has since been refactored heavily toward a UE4-first direction with more tooling, documentation, and smoke coverage.

## Why I made it

UE4.27 still matters in real production environments, but many newer tools and examples are written with UE5 assumptions. I wanted a workflow that stays realistic for teams and projects that still live on UE4.27.2.

## What it does

- Reads project, map, asset, and actor information from the open editor
- Exposes editor and content workflows in an MCP-friendly shape
- Supports practical operations across actors, assets, widgets, Blueprints, and inspection flows
- Keeps the implementation grounded in what stock UE4.27 Python can reliably support

## Repository

- GitHub: [conaman/unreal-mcp-ue4](https://github.com/conaman/unreal-mcp-ue4)

More detailed technical write-ups will be added here over time.
