# For the tests: answer-in-terminal.py <answer> <command...>
# Runs the command in a terminal, and types <answer> once it asks [y/N], as a person would. Prints
# what the command printed, and exits with its exit code. Not on Windows, which has no pty.
#
# (Not script: macOS's ends the terminal, cutting the command off, as soon as what's piped in to
# type runs out, and it reads what's piped in even just to run true.)
import os
import pty
import sys

answer, command = sys.argv[1], sys.argv[2:]
pid, terminal = pty.fork()
if pid == 0:
    os.execvp(command[0], command)

out = b""
while True:
    try:
        data = os.read(terminal, 1024)
    except OSError:  # Linux: the command has ended
        break
    if not data:  # macOS: the command has ended
        break
    asked = b"[y/N]" in out
    out += data
    if not asked and b"[y/N]" in out:
        os.write(terminal, answer.encode() + b"\n")

sys.stdout.write(out.decode(errors="replace"))
sys.exit(os.waitstatus_to_exitcode(os.waitpid(pid, 0)[1]))
