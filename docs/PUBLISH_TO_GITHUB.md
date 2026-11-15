# Uploading the source to Posegypt (manual authorization required)

Target repository: `https://github.com/f9933385-stack/Posegypt`.

The ChatGPT-connected GitHub account was read-only for this repository on
2026-11-12. Its `push` permission was `false`. Therefore these files are
**not uploaded to GitHub** and no commit or PR has been created.

**Do not place a personal access token in a chat, issue, README, .env, or commit.**
If a token was exposed, revoke it from GitHub → Settings → Developer settings →
Personal access tokens and create a replacement only if needed. Prefer `gh auth login`
(browser authorization) or installation of the GitHub App with write access.

## Windows PowerShell (recommended)

Install Git and GitHub CLI, then authorize GitHub **in your browser** using
`gh auth login`. Do not paste personal access tokens into chats.

Unzip the source package to a local directory, then use the existing-repository
workflow below. It preserves the remote repository history and avoids force
pushes. Do not extract files over an existing `.git/` directory.

## Existing-repository safe workflow

```powershell
gh auth login
git clone https://github.com/f9933385-stack/Posegypt.git
cd Posegypt
git switch -c kasher-development
# Copy all extracted source files into this directory. Do not copy any .git directory.
git add .
git commit -m "Add Kasher POS development source"
git push -u origin kasher-development
```

**Never** upload database files, encrypted backup passwords, tokens, `.env`, or
production user data. CI must pass before the PR is merged. The project is
not production-ready; see `IMPLEMENTATION_STATUS.md`.
