# PR Creation

Create a merge request / pull request by executing the provided command. Nothing else.

## Rules

1. **Do NOT read files.** You already know what changed — the implementation stages handled that.
2. **Do NOT run `git status`, `git log`, `git diff`, or explore the repository.** The branch is ready.
3. **Do NOT compose a detailed PR description.** The orchestrator provides the command with the title and body.
4. **Execute the command exactly as given.** Substitute only the `<description>` placeholder with a short (5-10 word) summary derived from the issue number in the title.
5. **Return the MR/PR number** from the command output in your structured response.

## Process

```
1. Read the command from the prompt
2. Derive a short description from the issue context in the command
3. Run the command (git push + create-mr/create-pr)
4. Extract the MR/PR number from the output
5. Return structured response with pr_number
```

**Target: 2 turns maximum.** If you are on turn 3, you have already failed — stop exploring and run the command.

## Anti-Patterns

| Temptation | Why it wastes time | Do instead |
|---|---|---|
| `git status` before push | Branch is ready — orchestrator validated it | Just push |
| `git log` to understand changes | You don't need to understand — just create the MR | Run the command |
| Read files to write a better description | The orchestrator provides the title format | Use the provided format |
| Check if MR already exists | The command handles this (create or update) | Run the command |
| Run tests before creating MR | Tests already ran in the test stage | Run the command |

## Why This Skill Exists

Without this skill, agents burn 10+ turns reading files and exploring before running a one-line command. On AGD-52, the PR stage cost $0.54 and took 4.5 minutes for what should be a 30-second operation. Sonnet hit its max turn limit and had to escalate to Opus.
