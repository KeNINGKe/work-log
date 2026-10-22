---
name: work-log
description: "Creates and updates two factual daily Markdown work logs shared by Codex and Claude Code: an easy-to-understand manager-facing summary and a complete technical record. In Codex desktop it gathers confirmed work from all Codex tasks active that day. Use whenever the user says ‘结束工作’, ‘整理日志’, ‘写工作日志’, ‘生成工作日志’, asks to summarize today's work across windows, or wants project work, learning, or colleague communication recorded in the daily log."
metadata:
  version: "2026.10.22"
---

# Work Log

Create two factual daily work logs through the bundled deterministic writer: an easy-to-understand manager-facing log and a comprehensive detailed work record.

## Output format

Output only the work summary and detailed work record. Start the simple log directly with the first numbered project/topic. Do not add salutations, greetings, introductory sentences, or closing remarks, even if an older sample or config includes them. The detailed log keeps its dated heading and project sections, without a boilerplate introduction.

## Plain-language requirement

Treat the manager-facing `points` as an explanation for a reader who does not know the project technology.

- Lead with what was accomplished, what problem was solved, and what result was obtained.
- Translate necessary jargon on first use; prefer ordinary Chinese when the technical term adds no value.
- Keep only one or two numbers that directly support the conclusion. Move remaining parameters and test data to `details`.
- Do not write unexplained stage codes, abbreviations, variable names, file paths, commands, or dense strings of metrics in `points`.
- State completion boundaries plainly, for example “独立供电模式已完成，整个开关级阶段尚未结束”.
- Treat manager-facing bullets as distinct outcomes, not as a list of implementation dimensions. Default to one or two bullets per topic; add more only for genuinely separate outcomes or boundaries. The simple log allows at most 5 points per project/topic per day, each point 1–2 sentences (2026-09-17 user request; supersedes the 2026-09-08 no-cap rule).
- Do not split one deliverable into separate bullets for layout, styling, bug fixes, generated files, and tests. Merge those into one outcome statement and keep the breakdown in `details`.
- Keep ONE topic per project per day: merge all workstreams of the same project (core and supporting, from Claude and Codex fragments alike) into a single first-level topic. Order points by importance so core deliverables lead and supporting work cannot displace the primary milestone.

Read [references/plain-language-sample.md](references/plain-language-sample.md) completely before drafting. Match its level of explanation, not its project-specific facts.

## Workflow

1. Read [references/logging-rules.md](references/logging-rules.md) completely.
2. Read the live sample file configured in [references/config.json](references/config.json) before drafting the entry. If it is unavailable, use [references/plain-language-sample.md](references/plain-language-sample.md).
3. Determine collection scope:
   - In Codex desktop, for a daily-log trigger, read [references/codex-cross-task.md](references/codex-cross-task.md) completely and collect confirmed work from every Codex task with activity during the current local day.
   - In Claude Code, collect the current conversation; the final rebuild also includes Claude and Codex fragments already saved for the day.
   - Outside those environments, collect the current conversation only.
4. Use only facts supported by the collected conversations or explicitly supplied by the user. Treat a working directory as project context, not as evidence of completed work.
5. Do not inspect Git history, commits, unrelated files, or other projects to invent or infer work items.
6. Draft two levels of content for every topic: `points` is a plain-language manager-facing summary capped at 5 points per project/topic, each point 1–2 sentences (2026-09-17 user request, superseding the 2026-09-08 no-cap rule); still merge any two points that describe the same deliverable; `details` is the complete confirmed record and may retain necessary terminology, parameters, progress, problems and handling, outputs and verification, decisions, and follow-ups when those facts are supported. Before saving, compare every pair of `points`; if they describe the same deliverable or answer the same “what changed?” question, merge them.
7. Build one JSON payload per collected session/task using the schema below. Include the complete confirmed facts for that session because saving the same session again replaces its earlier fragment. Use the Codex thread ID as session_id for other Codex tasks.
8. Save each JSON payload as a UTF-8 temporary file, then run:

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File "D:\25294\desktop\日志agent\work-log\scripts\save-work-log.ps1" -InputFile "<temporary-json-path>" -DeleteInput
   ```

9. After all payloads are saved, report both Markdown paths, the number of Codex tasks inspected, and the topics recorded. If no confirmed facts exist and no earlier entries exist for today, do not fabricate content; explain that no log file was generated.

## Runtime metadata

The prompt hook normally adds `WORK_LOG_SOURCE`, `WORK_LOG_SESSION_ID`, and `WORK_LOG_CWD` to the conversation context. Use those exact values in the payload.

If hook metadata is unavailable:

- Set `source` to `codex` or `claude` according to the active agent.
- Set `cwd` to the current working directory.
- Set `session_id` to `manual-<source>-<date>-<project-folder>` so repeated saves update rather than duplicate the entry.

## Payload schema

```json
{
  "date": "2026-08-07",
  "source": "codex",
  "session_id": "session identifier from hook context",
  "cwd": "D:\\path\\to\\project",
  "items": [
    {
      "key": "project:d:\\path\\to\\project",
      "title": "项目或工作主题",
      "points": [
        "面向领导的合并摘要，每个主题最多 5 条、每条 1-2 句话（2026-09-17 起恢复限制）。",
        "说明完成了什么、解决了什么问题和形成了什么结果。"
      ],
      "details": [
        "完整记录已确认的工作进展和具体处理过程。",
        "可记录问题与处理、产出与验证、决策和有事实依据的待跟进事项，不设五条上限。"
      ]
    }
  ]
}
```

Use a stable lowercase `key` so entries for the same topic merge:

- Project work: always the path-only key `project:<normalized-current-project-path>`, with the same title in every fragment of the day (Claude and Codex alike), so one project renders as ONE first-level topic. Multiple workstreams of the same project merge into that topic: combine points by importance (respecting the 5-point per-topic cap) and keep full specifics in `details`. Never append a `|workstream:` suffix to a project key.
- Learning explicitly mentioned by the user: `learning:<topic>`
- Colleague communication explicitly mentioned by the user: `communication:<topic>`
- Other confirmed work: `work:<stable-topic>`

Omit categories, points, and details that have no supporting facts. When `details` is omitted for an older fragment, the writer falls back to `points`. Never add placeholder accomplishments, learning, communication, decisions, results, or plans.

## Trigger behavior

- In Codex desktop, “结束工作” and “整理日志” first refresh every same-day Codex task fragment, then rebuild today's Markdown from those tasks plus saved Claude Code fragments.
- In Claude Code, the same triggers refresh the current Claude session and rebuild from all fragments already saved that day; they cannot directly read unsaved Codex desktop tasks.
- Never ask for confirmation when the facts are clear. Ask only when two plausible interpretations would materially change the log.
