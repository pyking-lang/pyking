#!/usr/bin/env python3
"""Publishes the website: what `make website-release` runs. It builds the
site from HEAD with its address set, commits it to the GitHub Pages
repository SITE_REPO -- one commit per upload, on top of the last, naming
the commit of this repository it was built from -- pushes it with gh,
makes sure Pages serves that branch over HTTPS, and waits until the site
answers with what was built. See README.md beside this file
("Publishing").

Usage: python3 tools/site/publish.py [--yes]

Data structures:
    Refusal -- why the website cannot be published, as a message.

Functions:
    preflight() -- checks everything before anything is built or pushed.
    build() -- builds website/ for SITE_URL.
    fill(clone, commit) -- replaces a clone's files with website/'s.
    configure_pages() -- has Pages serve SITE_BRANCH's root over HTTPS.
    wait_served(commit) -- waits until Pages serves this build.
    publish(assume_yes) -- all of the above, in order.
    main(argv) -- the command-line entry point.
"""

import argparse
import importlib.util
import json
import os
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent

# site.py beside this file, by its path: `import site` is Python's own module.
_spec = importlib.util.spec_from_file_location("website", HERE / "site.py")
website = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(website)

# The code repository, which HEAD must be pushed to, and the organisation
# site: GitHub Pages serves a repository named <owner>.github.io at the
# root of https://<owner>.github.io/, with a certificate of its own.
CODE_REPO = "pyking-lang/pyking"
SITE_REPO = "pyking-lang/pyking-lang.github.io"
SITE_URL = "https://pyking-lang.github.io/"
SITE_BRANCH = "main"
# How long Pages may take to build and serve an upload.
SERVE_TIMEOUT = 600


class Refusal(Exception):
    """Why the website cannot be published: a message for the user."""


def run(command, **kwargs):
    """Runs a command, printing it first; raises Refusal when it fails.
    [String] -> {..} -> CompletedProcess"""
    print("  $ " + shlex.join(str(c) for c in command))
    try:
        return subprocess.run([str(c) for c in command], check=True, **kwargs)
    except FileNotFoundError:
        raise Refusal(f"{command[0]} not found")
    except subprocess.CalledProcessError as e:
        raise Refusal(f"`{shlex.join(str(c) for c in command)}` failed (exit {e.returncode})")


def answer(command, cwd=None):
    """A command's output, or None when it fails. [String] -> Path? -> String?"""
    try:
        result = subprocess.run([str(c) for c in command], capture_output=True, text=True,
                                cwd=cwd)
    except FileNotFoundError:
        return None
    return result.stdout.strip() if result.returncode == 0 else None


def version():
    """The version, from VERSION at the root. () -> String"""
    return (REPO / "VERSION").read_text().strip()


def preflight():
    """Checks, before anything is built: gh and git, a logged-in gh, a git
    identity for the commit, no uncommitted change to a tracked file, HEAD
    already on GitHub in CODE_REPO, and SITE_REPO existing and public.
    Answers HEAD. () -> String"""
    if not shutil.which("gh") or not shutil.which("git"):
        raise Refusal("git and gh (the GitHub CLI) are needed: `brew install gh`, "
                      "then `gh auth login`")
    if subprocess.run(["gh", "auth", "status"], capture_output=True).returncode:
        raise Refusal("gh is not logged in; run `gh auth login`")
    # Asked from outside any repository, as the clone will be: a name set
    # only in this repository's own config is not used there.
    for key in ("user.name", "user.email"):
        if not answer(["git", "config", key], cwd=tempfile.gettempdir()):
            raise Refusal(f"git has no {key}, which the website's commit needs: "
                          f'git config --global {key} "..."')
    changed = answer(["git", "-C", REPO, "status", "--porcelain", "--untracked-files=no"])
    if changed is None:
        raise Refusal(f"{REPO} is not a git repository, so the website would name no commit")
    if changed:
        files = [line.split(None, 1)[1] for line in changed.splitlines()]
        raise Refusal("the working tree has uncommitted changes, so the website would "
                      "not be the commit it names: " + ", ".join(files[:6])
                      + (" ..." if len(files) > 6 else "")
                      + "\n  Commit or discard them, and publish again.")
    commit = answer(["git", "-C", REPO, "rev-parse", "HEAD"])
    if subprocess.run(["gh", "api", f"repos/{CODE_REPO}/commits/{commit}", "--silent"],
                      capture_output=True).returncode:
        raise Refusal(f"HEAD ({commit[:12]}) is not on GitHub in {CODE_REPO}; push it "
                      "first (`git push`), so the website names a commit others can see")
    viewed = answer(["gh", "repo", "view", SITE_REPO, "--json", "visibility"])
    if viewed is None:
        raise Refusal(f"the repository {SITE_REPO} does not exist or is not reachable; "
                      f"create it with\n    gh repo create {SITE_REPO} --public "
                      '--description "The Pyking website"')
    state = json.loads(viewed)
    if state.get("visibility") != "PUBLIC":
        raise Refusal(f"{SITE_REPO} is {state.get('visibility', '?').lower()}; Pages "
                      "serves an organisation's site from a public repository:\n"
                      f"    gh repo edit {SITE_REPO} --visibility public "
                      "--accept-visibility-change-consequences")
    return commit


def build():
    """Builds website/ with its address set to SITE_URL, at the root, as
    `make website` would otherwise build it. () -> ()"""
    os.environ["PYKING_SITE_URL"] = SITE_URL
    os.environ["PYKING_SITE_BASE"] = "/"
    if website.OUTPUT.exists():
        shutil.rmtree(website.OUTPUT)
    website.main(["build"])
    if not (website.OUTPUT / "index.html").is_file():
        raise Refusal(f"the build wrote no {website.OUTPUT.relative_to(REPO)}/index.html")


def fill(clone, commit):
    """Replaces everything in a clone but .git with website/'s files, and
    adds .nojekyll, without which Pages would leave out every path
    starting with `_`, Astro's _astro/ among them. Path -> String -> ()"""
    for path in clone.iterdir():
        if path.name == ".git":
            continue
        if path.is_dir() and not path.is_symlink():
            shutil.rmtree(path)
        else:
            path.unlink()
    shutil.copytree(website.OUTPUT, clone, dirs_exist_ok=True)
    (clone / ".nojekyll").write_text("")
    (clone / "README.md").write_text(
        f"# The Pyking website\n\n{SITE_URL}\n\nGenerated by `make website-release` in "
        f"{CODE_REPO} from commit {commit}; do not edit here.\n")


def configure_pages():
    """Has Pages serve SITE_BRANCH's root, creating the site if there is
    none, and enforces HTTPS where it is not. () -> ()"""
    found = answer(["gh", "api", f"repos/{SITE_REPO}/pages"])
    source = {"branch": SITE_BRANCH, "path": "/"}
    if found is None:
        run(["gh", "api", "-X", "POST", f"repos/{SITE_REPO}/pages", "--input", "-"],
            input=json.dumps({"build_type": "legacy", "source": source}), text=True,
            stdout=subprocess.DEVNULL)
        found = answer(["gh", "api", f"repos/{SITE_REPO}/pages"]) or "{}"
    pages = json.loads(found)
    if pages.get("build_type") != "legacy" or pages.get("source") != source:
        run(["gh", "api", "-X", "PUT", f"repos/{SITE_REPO}/pages", "--input", "-"],
            input=json.dumps({"build_type": "legacy", "source": source}), text=True)
    if not pages.get("https_enforced"):
        # A github.io site has its certificate at once; this redirects http.
        run(["gh", "api", "-X", "PUT", f"repos/{SITE_REPO}/pages", "-F",
             "https_enforced=true"])


def served(path, mark):
    """The bytes Pages serves at a path, past its cache, or None.
    String -> String -> Bytes?"""
    try:
        with urllib.request.urlopen(f"{SITE_URL}{path}?v={mark}", timeout=20) as reply:
            return reply.read()
    except OSError:
        return None


def wait_served(commit):
    """Waits until Pages has built this upload -- its README.md, which
    names the commit, is served -- and serves the front page over HTTPS
    as it was built; refuses after SERVE_TIMEOUT. String -> ()"""
    wanted = (website.OUTPUT / "index.html").read_bytes()
    deadline = time.monotonic() + SERVE_TIMEOUT
    status = "not started"
    print(f"  waiting for {SITE_URL} to serve it (up to {SERVE_TIMEOUT // 60} minutes) ...")
    while time.monotonic() < deadline:
        latest = answer(["gh", "api", f"repos/{SITE_REPO}/pages/builds/latest"])
        build_ = json.loads(latest) if latest else {}
        status = build_.get("status", status)
        if status == "errored":
            raise Refusal(f"the website is pushed, but Pages failed to build it: "
                          f"{(build_.get('error') or {}).get('message')}")
        readme = served("README.md", commit[:12]) or b""
        if status == "built" and commit.encode() in readme \
                and served("", commit[:12]) == wanted:
            return
        time.sleep(10)
    raise Refusal(f"the website is pushed, but {SITE_URL} did not serve it within "
                  f"{SERVE_TIMEOUT // 60} minutes (Pages says {status!r}); see "
                  f"https://github.com/{SITE_REPO}/settings/pages")


def confirm(question):
    """Asks a yes/no question; anything but yes, or no terminal, is no.
    String -> Bool"""
    try:
        reply = input(question)
    except EOFError:
        reply = ""
    return reply.strip().lower() in ("y", "yes")


def publish(assume_yes):
    """Checks, builds, asks, commits website/ to SITE_REPO and pushes it,
    configures Pages, and waits for it to be served. Answers whether it
    published. Bool -> Bool"""
    commit = preflight()
    build()
    v = version()
    files = sum(1 for path in website.OUTPUT.rglob("*") if path.is_file())
    size = sum(path.stat().st_size for path in website.OUTPUT.rglob("*")
               if path.is_file()) / 1048576
    print(f"\nAbout to publish the website of Pyking {v}, built from {commit[:12]}:")
    print(f"  1. commit website/ ({files} files, {size:.1f} MB) to {SITE_REPO} "
          f"on {SITE_BRANCH}, and push it")
    print(f"  2. have Pages serve it at {SITE_URL}, over HTTPS")
    if not assume_yes and not confirm("Publish? [y/N] "):
        print("website-release: nothing was published.")
        return False
    with tempfile.TemporaryDirectory(prefix="pyk-website-") as directory:
        clone = Path(directory) / "site"
        run(["gh", "repo", "clone", SITE_REPO, clone, "--", "--quiet"])
        # On top of the last upload, whatever the default branch is; the
        # first upload starts the branch.
        if answer(["git", "-C", clone, "ls-remote", "--exit-code", "--heads", "origin",
                   SITE_BRANCH]) is not None:
            run(["git", "-C", clone, "checkout", "--quiet", "-B", SITE_BRANCH,
                 f"origin/{SITE_BRANCH}"])
        else:
            run(["git", "-C", clone, "checkout", "--quiet", "--orphan", SITE_BRANCH])
        fill(clone, commit)
        run(["git", "-C", clone, "add", "--all"])
        if subprocess.run(["git", "-C", clone, "diff", "--cached", "--quiet"]).returncode:
            run(["git", "-C", clone, "commit", "--quiet", "-m",
                 f"Pyking {v} website, from {CODE_REPO}@{commit[:12]}"])
            run(["git", "-C", clone, "push", "origin", f"HEAD:{SITE_BRANCH}"])
        else:
            print(f"  ({SITE_REPO} already holds this website)")
    configure_pages()
    wait_served(commit)
    print(f"\nwebsite-release: SUCCEEDED -- {SITE_URL} is Pyking {v}'s website, "
          f"built from {commit[:12]}.")
    return True


def main(argv=None):
    """The command-line entry point. [String]? -> Int"""
    parser = argparse.ArgumentParser(prog="publish.py",
                                     description="Publish the Pyking website.")
    parser.add_argument("--yes", action="store_true", help="do not ask first")
    args = parser.parse_args(argv)
    try:
        return 0 if publish(args.yes) else 1
    except Refusal as refusal:
        print(f"website-release: {refusal}", file=sys.stderr)
        print("website-release: FAILED -- see above.")
        return 1


if __name__ == "__main__":
    sys.exit(main())
