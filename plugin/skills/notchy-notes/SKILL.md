---
name: notchy-notes
description: Read and update the user's note and task list in the Notchy notch panel on their Mac. Use when the user asks to put a task, reminder or note "in the notch" / "в чёлку" / "в Notchy" / "в заметки" / "в задачи", asks what is on their notch task list, or asks to tick a task off. Also use when the user asks you to remember a follow-up for them to do by hand.
---

# Notchy notes and tasks

The notch panel on the user's Mac has a note and a task list (tab with the checklist icon). They live in one file the panel shares with this script, so anything you add shows up in the notch at once, marked with Claude's asterisk.

Run the script next to this file with `python3` (standard library only):

```bash
python3 "<this skill's base directory>/notes.py" list                    # the note and the tasks, numbered
python3 "<this skill's base directory>/notes.py" add "Call the bank"     # one or more tasks
python3 "<this skill's base directory>/notes.py" done 2                  # numbers from `list`
python3 "<this skill's base directory>/notes.py" undone 2
python3 "<this skill's base directory>/notes.py" remove 3
python3 "<this skill's base directory>/notes.py" note "Wi-Fi for guests: on the fridge"   # appends a line
python3 "<this skill's base directory>/notes.py" note --replace "..."   # replaces the whole note
```

- Run `list` before `done`, `undone` or `remove`: numbers shift as tasks are added.
- Tasks are for the user: short, imperative, one action each ("Renew the domain before 20 Nov"), in the user's language. Never put secrets, tokens or passwords there.
- Add only what the user asked for, or what they agreed to when you offered. Don't fill the list with your own work items.
- After a change, tell the user in one line what is now in the notch.
- The file is `~/Library/Application Support/Notchy/notes.json`. If Notchy is not running the change is still saved and shows up when it starts.
