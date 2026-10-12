#!/usr/bin/env python3
"""Runs a real Claude Code session in a pty nobody sees and checks that the text typed in its
prompt and not sent comes back after Fleet restarts it. The session is ended the way the hook's
`relaunch` ends it (its note, then SIGTERM) and resumed the way the fish function resumes it;
what its prompt box holds is read off the file Fleet's mod keeps of it, not off the screen.
Costs one haiku turn: a session with no turn has no transcript to resume.
Run after `fleet --install-hooks`."""
import os, pty, re, select, shutil, signal, sys, time, uuid

HOME = os.path.expanduser('~')
FLEET = HOME + '/.claude/fleet'
# Below ~, so that the folder is trusted as ~ is, and out of every project's own sessions.
CWD = HOME + '/.cache/fleet/test-draft'
DRAFT = 'half a sentence, not sent'
sid = str(uuid.uuid4())
# As the fish function sets FLEET_SHELL: the pid of the claude's parent.
shell = str(os.getpid())
note = f'{FLEET}/restart/{shell}'
mirror = f'{FLEET}/state/{sid}.draft'
transcripts = f"{HOME}/.claude/projects/{re.sub('[^A-Za-z0-9]', '-', CWD)}"

if not os.path.exists(FLEET + '/mod/hooks/register.ts'):
    sys.exit(f'no mod in {FLEET}/mod — run: fleet --install-hooks')
os.makedirs(CWD, exist_ok=True)
# No marker of a session this is run from: its child would save no transcript, and Fleet's hook
# would take the caller's claude for this one. FLEET_TEST_TTY keeps Jarvis from asking it aloud.
env = {k: v for k, v in os.environ.items() if not k.startswith(('CLAUDE', 'FLEET_SHELL'))}
env.update(TERM='xterm-256color', FLEET_SHELL=shell, FLEET_TEST_TTY='??', DISABLE_AUTOUPDATER='1')
fail = 0


def read(path):
    try:
        with open(path) as f:
            return f.read()
    except FileNotFoundError:
        return None


class Session:
    def __init__(self, *argv):
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.chdir(CWD)
            os.execvpe('claude', ['claude', '--model', 'haiku', *argv], env)

    # The screen is read and dropped: a pty nobody reads fills up and the session stops drawing.
    def wait(self, seconds, until=lambda: False):
        end = time.time() + seconds
        while time.time() < end:
            if until():
                return True
            if select.select([self.fd], [], [], 0.1)[0]:
                try:
                    os.read(self.fd, 65536)
                except OSError:  # the session is gone
                    time.sleep(0.1)
        return False

    def keys(self, text):
        os.write(self.fd, text.encode())

    def end(self):
        os.kill(self.pid, signal.SIGTERM)
        self.wait(10, lambda: os.waitpid(self.pid, os.WNOHANG)[0] != 0)


def check(name, ok, got=None):
    global fail
    print(f"  {'ok  ' if ok else 'FAIL'}  {name}" + ('' if ok else f' — got {got!r}'))
    fail |= not ok


def holds(session, text, name):
    check(name, session.wait(15, lambda: read(mirror) == text), read(mirror))


try:
    first = Session('--session-id', sid, 'Reply with the single word ok and nothing else, no tools.')
    done = first.wait(180, lambda: '"state":"ready"' in (read(f'{FLEET}/state/{sid}.json') or ''))
    check('a first turn ended', done)
    first.keys(DRAFT)
    holds(first, DRAFT, 'the text typed and not sent is kept on disk')
    # relaunch, in the hook: the reason, the note, the kill
    os.makedirs(FLEET + '/restart', exist_ok=True)
    for path, text in ((note + '.why', 'test-draft.py'), (note, sid)):
        with open(path, 'w') as f:
            f.write(text + '\n')
    first.end()
    time.sleep(1)
    check('the end Fleet causes leaves it there', read(mirror) == DRAFT, read(mirror))
    # the fish function: the note goes, the session comes back
    os.remove(note)
    os.remove(note + '.why')
    second = Session('--resume', sid)
    second.wait(60, lambda: (read(f'{FLEET}/state/{sid}.shell') or '').startswith(f'{second.pid} '))
    second.wait(4)
    second.keys(' and more')
    holds(second, DRAFT + ' and more', 'the session started again has it back in its prompt')
    second.keys('\x15')
    holds(second, '', 'a prompt emptied empties the file')
    second.keys('left behind')
    holds(second, 'left behind', 'and it follows what is typed next')
    second.end()
    time.sleep(1)
    # Gone with the hook's `end`, or emptied by the mod's last look at a box already taken down.
    check('an end Fleet did not cause keeps no text', not read(mirror), read(mirror))
finally:
    for path in (note, note + '.why', mirror, f'{transcripts}/{sid}.jsonl'):
        if os.path.exists(path):
            os.remove(path)
    shutil.rmtree(f'{transcripts}/{sid}', ignore_errors=True)

print('all passed' if not fail else 'FAILED')
sys.exit(fail)
