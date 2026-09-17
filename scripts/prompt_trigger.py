import argparse
import json
import re
import sys


def main() -> int:
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--source", choices=("codex", "claude"), required=True)
    args = parser.parse_args()

    raw = sys.stdin.read()
    if not raw.strip():
        return 0

    try:
        event = json.loads(raw)
    except (TypeError, ValueError):
        return 0

    prompt = str(event.get("prompt") or "")
    normalized = re.sub(r"\s+", "", prompt).strip("。！!？?，,")
    pattern = re.compile(
        r"^(?:请|请帮我|帮我)?"
        r"(?:结束工作|整理日志|整理一下日志|"
        r"整理(?:一下)?(?:今天|今日|本日)?的?工作日志|"
        r"写(?:一下)?(?:今天|今日|本日)?的?工作日志|"
        r"生成(?:今天|今日|本日)?的?工作日志)"
        r"(?:吧|一下)?$"
    )
    if not pattern.fullmatch(normalized):
        return 0

    session_id = str(event.get("session_id") or "")
    cwd = str(event.get("cwd") or "")
    scope_instruction = (
        "In Codex desktop, collect confirmed work from all Codex tasks active during the current "
        "Asia/Shanghai day, following the skill's cross-task workflow. You must paginate every candidate "
        "thread back to the start of the local day; recent turns or compacted context are not sufficient. "
        "Treat task titles and summaries as navigation only, not as facts, and do not let later supporting "
        "work replace earlier core project milestones."
        if args.source == "codex"
        else "Use confirmed facts from this Claude conversation; the rebuild will also include fragments already saved today."
    )
    context = "\n".join(
        (
            "This is an explicit work-log trigger. Load and follow the installed work-log skill.",
            "Complete the save operation before replying; do not merely draft the log in chat.",
            scope_instruction,
            "Do not use Git history as a work source.",
            f"WORK_LOG_SOURCE={args.source}",
            f"WORK_LOG_SESSION_ID={session_id}",
            f"WORK_LOG_CWD={cwd}",
        )
    )
    output = {
        "hookSpecificOutput": {
            "hookEventName": "UserPromptSubmit",
            "additionalContext": context,
        }
    }
    sys.stdout.write(json.dumps(output, ensure_ascii=False, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
