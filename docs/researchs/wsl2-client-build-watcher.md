# Research: a nodemon watcher that rebuilds the C++ client from WSL2

Date: 2026-08-12. Repo: `/home/nrechdan/projects/w2-server`. All paths are absolute unless prefixed by the repo root.

Everything marked **MEASURED** was reproduced on this machine (WSL 2, kernel `6.18.33.2-microsoft-standard-WSL2`, distro `Personal`, Visual Studio 18 Build Tools, MSBuild 18.8.2). Everything else is quoted from the source that owns it. Section 9 lists what could not be verified.

## Question / scope

Add a **nodemon** watcher on `packages/apps/client` — a git submodule holding a decompiled C++ Windows client built with Visual Studio / MSBuild — that rebuilds it on change, alongside the existing root `yarn dev`. The watcher runs on Linux inside WSL2; the build must run on the Windows toolchain.

The real question is not "what does the nodemon flag look like". It is **whether a Windows compiler can build this tree at all from where it currently lives**, and that turns out to be the load-bearing fact.

---

## Verdict up front

**The literal request does not work, and the blocker is not nodemon — it is the filesystem.**

The client source lives on the WSL2 **ext4** filesystem, so a Windows MSBuild must reach it through `\\wsl.localhost\`. That share is **case-sensitive**, and the MSVC toolchain assumes it is not. The build fails twice for that single reason (MEASURED, §3). The same tree builds cleanly, exit 0, when copied to NTFS (MEASURED, §3.4).

The two candidate locations each break the half the other one fixes:

| Client source lives on | MSBuild over it | Linux inotify over it |
| --- | --- | --- |
| WSL ext4, via `\\wsl.localhost\` (today) | **fails** — case-sensitivity | **works natively** (MEASURED) |
| `/mnt/c` (NTFS) | **works** (MEASURED) | **dead** — 0 events, needs `-L` polling (MEASURED) |

So any working shape must **watch on one side and build on the other**. Recommended shape, given the submodule is read-only from this repo (§2):

```jsonc
// root package.json — NOT in the submodule, which has no package.json and must not gain one
"watch:app:client": "nodemon -w ./packages/apps/client -e \"*\" -d 1 -x \"yarn build:app:client\"",
"build:app:client": "rsync -a --delete --exclude .git packages/apps/client/ /mnt/c/Temp/w2-client/ && \"$(wslpath -u \"$('/mnt/c/Program Files (x86)/Microsoft Visual Studio/Installer/vswhere.exe' -latest -products '*' -requires Microsoft.Component.MSBuild -find 'MSBuild\\**\\Bin\\MSBuild.exe')\")\" 'C:\\Temp\\w2-client\\TM.sln' -m -p:Platform=x86 -p:Configuration=Debug -nologo -noAutoResponse -nr:false -tl:off -v:m"
```

Three things about that snippet are deliberate and each is defended below: the name is `watch:app:client`, **not** `dev:app:client` (§6.1 — the root `dev` glob would otherwise swallow it and let a client compile error kill the web and Rust dev servers); the build runs against a copy on `C:` (§3); and MSBuild is invoked **directly**, never through `cmd.exe` (§4.1).

**Before building any of it, ask whether it should exist.** `CLAUDE.md` states client changes are authored in the `w2-client` repo and arrive here only as a pointer bump. A developer editing client C++ is, by that rule, working in the other repo on Windows — where Visual Studio already rebuilds on F7 and MSBuild's incremental build makes a watcher largely redundant. This watcher serves one narrow case: someone editing client sources from the Linux side of this repo, which the conventions say should not be happening. That is worth a decision before it is worth an implementation.

---

## 1. What the repo actually specifies

| Fact | Source |
| --- | --- |
| `"dev": "conc --kill-others-on-fail yarn:dev:*"` | `package.json:16` |
| `"dev:app:server"`, `"dev:app:web"` — the only two fan-out targets today | `package.json:17-18` |
| Yarn workspaces are **only** `packages/apps/server` and `packages/apps/web` — the client is not a workspace | `package.json:10-13` |
| `concurrently` 10.0.4, `@fission-ai/openspec` 1.8.0 | `package.json:20-23` |
| The nodemon pattern to mirror: `nodemon -w "./Cargo.toml" -w "./src" -e "*" -x "yarn dev:run"` | `packages/apps/server/package.json:6` |
| `nodemon` 3.1.14, a devDependency of `@app/server` only | `packages/apps/server/package.json:10` |
| Submodule `packages/apps/client` → `open-w2-project/w2-client`, branch `main` | `.gitmodules:1-4` |

The submodule is checked out and clean at `378561c68b2f8a476850bf1f2cf2dbb71c1b31c6` (MEASURED). It holds 458 files: 109 `.cpp`, 268 `.h`, one solution, one project.

### 1.1 The build inputs, verbatim

- Solution: `packages/apps/client/TM.sln`, one project `Projects\TMProject\TMProject.vcxproj`.
- Solution configurations: `Debug|x64`, `Debug|x86`, `Release|x64`, `Release|x86`. The solution maps **`x86` → project platform `Win32`** (`TM.sln`, `ProjectConfigurationPlatforms`). Build the `.sln` with `Platform=x86`; build the `.vcxproj` directly and it is `Platform=Win32`.
- `<PlatformToolset>v142</PlatformToolset>` (VS2019), `<WindowsTargetPlatformVersion>10.0`, `<ConfigurationType>Application`.
- No `OutDir`/`IntDir` override, so output lands at the MSBuild default `$(SolutionDir)$(Configuration)\` — i.e. `TMProject.exe` in `packages/apps/client/Release/`. Confirmed by the client's own CI artifact path.

**The canonical invocation already exists in the client repo** and should be matched rather than invented — `packages/apps/client/.github/workflows/msbuild.yml:19`:

```
msbuild /m /p:Platform=x86 /p:Configuration=${{matrix.build_configuration}} TM.sln
```

x64 is nominally configured but not usable as shipped: `Dependencies/Directx/Lib` contains only 32-bit import libraries, and the client's own README says so — "A compilação para x64 é possível, basta que seja utilizado a dependência para x64 do DirectX assim como corrigir problemas quanto a compilação para esta arquitetura" (`packages/apps/client/README.md`). **Use `x86`.**

---

## 2. Where the script may live — a hard constraint

`packages/apps/client` **has no `package.json`** (MEASURED). It cannot gain one: `CLAUDE.md` states "Never edit, stage, or commit inside that directory **from this repo**", and the same rule is restated in `openspec/config.yaml`.

Consequences, all forced:

- The client cannot become a Yarn workspace (that requires a manifest inside the submodule).
- The nodemon script must live in the **root** `package.json`, and `nodemon` must become a **root** devDependency, pinned exactly (`.yarnrc` sets `--add.exact true`): `"nodemon": "3.1.14"`, matching `@app/server`. It currently resolves at the root only by workspace hoisting, which is incidental, not a contract.
- Any `nodemon.json`, ignore list, or helper script goes in the repo root or a root `scripts/` directory — never inside the submodule.
- The `Release/`, `x64/`, `Win32/` build-output patterns are already in the submodule's own `.gitignore`, so in-tree artifacts would not dirty git status. They would still trigger the watcher — see §6.3.

---

## 3. The crux: MSBuild cannot build this tree over `\\wsl.localhost\`

The repo is on ext4 (`/dev/sdg`, MEASURED), not `/mnt/c`. `wslpath -w` resolves the client to:

```
\\wsl.localhost\Personal\home\nrechdan\projects\w2-server\packages\apps\client
```

Note the distro is named **`Personal`**, not `Ubuntu` — hardcoding a UNC path would break on this very machine. Always derive it with `wslpath -w`.

### 3.1 MSBuild itself is fine with UNC

`MSBuild.exe -version` invoked directly from a Linux cwd returns `MSBuild version 18.8.2+ce25c0108`, exit 0, with no UNC complaint (MEASURED). It loads the solution and the `.vcxproj` over the UNC path and evaluates properties correctly — the first real build attempt failed with `MSB8020` (missing toolset), quoting the full UNC path back, which proves project loading worked.

### 3.2 First failure: the compiler lowercases its intermediate path

With the toolset overridden to one that is installed (`-p:PlatformToolset=v145`), `cl.exe` starts, compiles `pch.cpp`, and dies (MEASURED):

```
error C1083: Cannot open compiler intermediate file:
'\\wsl.localhost\personal\home\nrechdan\projects\w2-server\packages\apps\client\projects\tmproject\release\tmproject.pch':
No such file or directory
```

Every segment is lowercased — `Personal`→`personal`, `Projects`→`projects`, `TMProject`→`tmproject`, `Release`→`release`. Harmless on NTFS. Fatal here, because the share is case-sensitive (MEASURED via PowerShell `Test-Path` over the UNC path):

```
Projects (correct case)            : True
projects (lowercase)               : False
TM.sln (correct case)              : True
tm.sln (lowercase)                 : False
Projects\TMProject\Release         : True
projects\tmproject\release         : False
```

Microsoft documents both the case-sensitivity and this exact class of breakage — <https://learn.microsoft.com/en-us/windows/wsl/case-sensitivity>:

> "Directories in the WSL (Linux) file system are case sensitive by default (and cannot be set to be case insensitive using the `fsutil.exe` tool)."

> "Some Windows applications, using the assumption that the file system is case insensitive, don't use the correct case to refer to files. For example, it's not uncommon for applications to transform filenames to use all upper or lower case. In directories marked as case sensitive, this means that **these applications can no longer access the files.**"

MSBuild case-folding UNC paths is a known, filed defect: <https://github.com/dotnet/msbuild/issues/7001> (building from `\\wsl$\Ubuntu-20.04\...`, MSB8064/MSB8065 from `Ubuntu-20.04` → `ubuntu-20.04`). Closed, not fixed.

### 3.3 Second failure: the source itself assumes case-insensitivity

Redirecting only the intermediates to NTFS (`-p:IntDir=C:\Temp\...\ -p:OutDir=C:\Temp\...\`) clears the PCH error — 20+ translation units then compile (MEASURED) — and immediately hits the next instance of the same root cause:

```
NewApp.cpp(19,10): error C1083: Cannot open include file: 'resource.h': No such file or directory
```

`Projects/TMProject/NewApp.cpp:19` says `#include "resource.h"`. The file on disk is `Projects/TMProject/Resource.h`. Two other files (`TMProject.h`, `TMProject.rc`) include it the same way. A sweep of the 115 other quoted includes found **no** further case mismatches (MEASURED) — this is the only one, but one is enough.

**This is unfixable from this repo.** Correcting it means editing a tracked file inside the submodule, which `CLAUDE.md` forbids. It is a `w2-client` change.

### 3.4 The same tree builds clean on NTFS

Copied verbatim to `C:\Temp\w2client-test` and built with the identical command (MEASURED):

```
TMProject.vcxproj -> C:\Temp\w2client-test\Release\TMProject.exe
--- exit 0 ---   (~10s wall, -m parallel, "All 2045 functions were compiled")
```

Nothing about MSBuild, WSL interop, or the project is broken. **Only the case-sensitivity of the ext4 share is.** Test artifacts were removed; the submodule and parent repo are clean (MEASURED).

### 3.5 A separate, machine-local blocker

This machine has **Build Tools only**, and only toolset **v145**; `Dependencies` show MSVC 14.44 and 14.51 (MEASURED). The project pins **v142**, so an unmodified build fails at `MSB8020: The build tools for Visual Studio 2019 (Platform Toolset = 'v142') cannot be found`. `-p:PlatformToolset=v143` fails the same way.

Two clean fixes; both are environment or `w2-client` work, not this repo's:

1. Install the VS2019 (v142) build tools — matches the project as pinned and as CI builds it.
2. Retarget the project in `w2-client`.

Do **not** paper over it with `-p:PlatformToolset=v145` in the dev script: it silently builds a different toolchain than CI. Also note the client README requires the **ATL** component, which is not installed here (MEASURED) — `VC/Tools/MSVC/*/atlmfc` is absent.

---

## 4. WSL2 interop gotchas

### 4.1 `cmd.exe` drops a UNC working directory; MSBuild does not

Launching a Windows process from a Linux cwd hands it the UNC path. `cmd.exe` rejects it (MEASURED):

```
'\\wsl.localhost\Personal\home\nrechdan\projects\w2-server\packages\apps\client'
CMD.EXE was started with the above path as the current directory.
UNC paths are not supported.  Defaulting to Windows directory.
CWD_IS=C:\Windows
```

PowerShell and `MSBuild.exe` both keep it. `pushd` is the documented workaround and does work — it maps the share to a spare drive letter, `Z:\home\nrechdan\...` (MEASURED), per <https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/pushd>:

> "If you specify a network path, the **pushd** command temporarily assigns the highest unused drive letter (starting with Z:) to the specified network resource."

**Practical rule: call `MSBuild.exe` directly and pass the solution as an absolute Windows path from `wslpath -w`.** Never route through `cmd.exe` or `VsDevCmd.bat` (a `.bat`, therefore `cmd.exe`) — that is the one component that loses the working directory. It also removes the whole class of bash→cmd quoting problems, which bit twice during this research.

The WSL docs promise to explain this and never do — <https://learn.microsoft.com/en-us/windows/wsl/filesystems> says Windows tools "Retain the working directory as the WSL command prompt (**for the most part -- exceptions are explained below**)" and the exceptions are absent from the page source. **The `C:\Windows` fallback is undocumented on learn.microsoft.com.**

### 4.2 MSBuild does not need a Developer Command Prompt

<https://learn.microsoft.com/en-us/cpp/build/msbuild-visual-cpp>:

> "In general, we recommend that you use Visual Studio to set project properties and invoke the MSBuild system. **However, you can use the MSBuild tool directly from the command prompt.**"

The Developer Command Prompt is framed throughout <https://learn.microsoft.com/en-us/visualstudio/ide/reference/command-prompt-powershell> as convenience — "you can enter the commands for different utilities **without having to know where they're located**" — never as a requirement. Confirmed empirically: a bare `MSBuild.exe` resolved the `Microsoft.Cpp` targets and compiled 20+ files of `TMProject.vcxproj` with no `VsDevCmd` in the environment (MEASURED, §3.3).

### 4.3 Locating MSBuild — the canonical vswhere command silently finds nothing here

<https://github.com/microsoft/vswhere/wiki/Find-MSBuild> gives:

```
vswhere -latest -requires Microsoft.Component.MSBuild -find MSBuild\**\Bin\MSBuild.exe
```

at the fixed path `"%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"`. **On this machine it returns nothing and exits 0** (MEASURED), because vswhere's default product filter excludes Build Tools. The wiki says so in one line — "to include Build Tools, add `-products *`" — and that line is the difference between working and silently doing nothing:

```
$ vswhere -latest -products '*' -requires Microsoft.Component.MSBuild -find 'MSBuild\**\Bin\MSBuild.exe'
C:\Program Files (x86)\Microsoft Visual Studio\18\BuildTools\MSBuild\Current\Bin\MSBuild.exe
```

Two consequences for the script: pass `-products '*'`, quote the `MSBuild\**\Bin\MSBuild.exe` glob so bash leaves it alone, and **guard on empty output rather than on exit code** — vswhere exits 0 when it finds nothing.

### 4.4 MSBuild switches worth passing

From <https://learn.microsoft.com/en-us/visualstudio/msbuild/msbuild-command-line-reference>:

> "Every switch is available in two forms: `-switch` and `/switch`… Switches aren't case-sensitive. **If you run MSBuild from a shell other than the Windows command prompt, lists of arguments to a switch (separated by semicolons or commas) might need single or double quotes**."

- `-m` / `-maxCpuCount` — "If you don't include this switch, the default value is 1. If you include this switch without specifying a value, MSBuild uses up to the number of processors."
- `-v:m` — levels are `q[uiet]`, `m[inimal]`, `n[ormal]` (default), `d[etailed]`, `diag[nostic]`.
- **`-nr:false`** — node reuse defaults to **True**: "Nodes remain after the build finishes so that subsequent builds can use them (default)." In a watch loop those workers outlive the process the watcher kills. Turn it off.
- **`-noAutoResponse`** — MSBuild otherwise silently reads `MSBuild.rsp` from its own Bin directory (observed in test output). Off, for reproducibility.
- **`-tl:off`** — the terminal logger is documented as unstable ("Don't parse the output or otherwise rely on it remaining unchanged in future versions") and its links are broken on UNC (<https://github.com/dotnet/msbuild/issues/9033>, closed **Not planned**).

`bash` in WSL passes both `/p:` and `-p:` through unmangled — verified in a single command line (MEASURED) — consistent with "Parameters are passed to the Windows binary unmodified" (<https://learn.microsoft.com/en-us/windows/wsl/filesystems>). The Git-Bash/MSYS path-mangling problem is a different environment and does not apply.

---

## 5. Filesystem watching across the boundary

### 5.1 On ext4, Windows writes **do** fire Linux inotify — MEASURED

A `fs.watch` (inotify) watcher on `/home/nrechdan/.w2-inotify-test`, with writes driven from PowerShell over `\\wsl.localhost\`:

```
[+3.0s]  EVENT rename from-linux-1.txt     <- Linux write   (control)
[+6.2s]  EVENT rename from-windows.txt     <- Windows write (create)
[+6.2s]  EVENT change from-windows.txt
[+10.5s] EVENT change from-windows.txt     <- Windows append
[+13.6s] EVENT rename from-linux-2.txt     <- Linux write   (control)
```

This is the **opposite** of the widely-cited WSL2 watching problem, and the asymmetry is structural rather than lucky. Microsoft's own architecture doc, `doc/docs/technical-documentation/plan9.md` in microsoft/WSL, explains why:

> "**Plan9 is a Linux process that hosts a plan9 filesystem server** for WSL1 and WSL2 distributions. It's created by init in each distribution."

Because the server for `\\wsl.localhost\` is a **Linux process inside the distro**, a Windows write lands on ext4 through ordinary `write(2)`, and the kernel emits inotify events exactly as for any local writer. There is no notification code in `src/linux/plan9/` because none is needed.

**Caveat, stated honestly: no Microsoft prose asserts this.** The behaviour is derived from Microsoft's architecture doc plus the WSL source, and confirmed by the measurement above. See §9.

### 5.2 On `/mnt/c`, inotify is dead — MEASURED, and worse than documented

The identical test on `/mnt/c/Temp/w2-inotify-test` produced **zero events in 24 seconds** — not for the Windows writes, and **not even for the Linux writes**:

```
[+0.0s]  watching /mnt/c/Temp/w2-inotify-test with fs.watch (inotify)
[+24.0s] --- done ---
```

Confirmed with real nodemon 3.1.14 (MEASURED):

| nodemon on `/mnt/c` | restarts observed |
| --- | --- |
| `-w <dir> -e "*"` (inotify) | **0** |
| `-w <dir> -e "*" -L` (polling) | **2** — both the Windows and the Linux write |

The tracking issue is **microsoft/WSL#4739**, "[WSL2] File changes made by Windows apps on Windows filesystem don't trigger notifications for Linux apps" — **open since 2019-12-06**, 659 reactions, locked October 2024. <https://github.com/microsoft/WSL/issues/4739>

Microsoft's design statement, `craigloewen-msft` (MEMBER), <https://github.com/microsoft/WSL/issues/4701#issuecomment-558280473>:

> "**We need to add file watch capabilities to the Plan9 server that serves files to a WSL2 distro**, and we're tracking that work item here: #4739. […] For the future please try to run your Linux apps from your Linux root file system!"

And the most recent, 2024-10-25, <https://github.com/microsoft/WSL/issues/4739#issuecomment-2438124058>:

> "**We're still tracking this as a known issue**, and if you're experiencing this you can see some of the alternative solutions in the thread above to help it, such as using VS Code Remote, **using `\\wsl.localhost\` to access the files from the Linux file system**, etc."

Note that Microsoft's recommended workaround is *exactly the layout this repo already has*. It worked in WSL1 — <https://learn.microsoft.com/en-us/windows/wsl/release-notes>, Build 14942: "inotify support for notifications generated from Windows applications on DrvFs is now in". WSL2's 9p-backed DrvFs never got it.

**Polling is not a Microsoft recommendation.** The word does not appear as guidance in any WSL doc checked (filesystems, file-permissions, compare-versions, faq, setup/environment, wsl-config, case-sensitivity, release-notes). It is a community workaround, and the cost is real — nodemon's own README:

> "In some networked environments (such as a container running nodemon reading across a mounted drive), you will need to use the `legacyWatch: true` which enables Chokidar's polling… **Though this should be a last resort as it will poll every file it can find.**"

For this tree that is 458 files re-`stat`ed every 100 ms (`-P` default, per `doc/cli/options.txt`). Tolerable at this size; raise `-P` to 500–1000 ms if it shows up in `top`.

### 5.3 The direction that is genuinely broken for this repo

Not Windows→Linux. **Linux→Windows on the ext4 tree.** `ReadDirectoryChangesW` — what .NET `FileSystemWatcher` and Visual Studio's file-change tracking are built on — does not work over `\\wsl$`:

**microsoft/WSL#7674**, "`ReadDirectoryChangesW` method is unsupported on `\\wsl$` paths" — open since 2021-11-12, **zero Microsoft response in over four years**. <https://github.com/microsoft/WSL/issues/7674>

> "The `ReadDirectoryChangesW` function cannot be used to recursively watch a folder path such as `\\$wsl\Ubuntu\home`, the method invocation returns a non-normal status code."

So if anyone opens `TM.sln` in Visual Studio over the UNC path, VS will not notice Linux-side edits and will need manual refreshes. Another argument for keeping the Windows-side build against a Windows-side copy.

### 5.4 Two smaller boundary facts

**Permissions.** <https://learn.microsoft.com/en-us/windows/wsl/file-permissions>:

> "Accessing Linux files via `\\wsl$` will use the default user of your WSL distribution… **The default umask is applied when creating a new file inside of a WSL distribution from Windows. The default umask is `022`**."

MSBuild outputs written into the ext4 tree over UNC would be mode 644 — **not executable**. Irrelevant for a Windows `.exe`, relevant the moment anything Linux-side tries to exec a build artifact.

**Line endings.** Nothing is automatic. <https://learn.microsoft.com/en-us/windows/wsl/tutorials/wsl-git>:

> "If you are working with the same repository folder between Windows, WSL, or a container, be sure to set up consistent line endings… **Git may report a large number of modified files that have no differences aside from their line endings.**"

The trap is specific: Git for Windows ships `core.autocrlf=true`, Git inside the distro does not. If the client is ever cloned separately on the Windows side (§7), the two clones will disagree about every line unless a `.gitattributes` settles it — and that file belongs to `w2-client`, not here.

---

## 6. Wiring it into this repo

### 6.1 Do not name it `dev:app:client`

`package.json:16` is `conc --kill-others-on-fail yarn:dev:*`. That glob expands to **every** root script matching `dev:*`, so a script named `dev:app:client` joins the default `yarn dev` fan-out automatically — and `--kill-others-on-fail` then means **a C++ compile error takes down the Next.js dev server and the Rust server**.

`CLAUDE.md` already flags this coupling as a hazard for two apps. A third app whose build is the slowest, the most fragile, and the one requiring a Windows toolchain makes `yarn dev` unusable for anyone without Visual Studio installed — including CI and any Linux-only contributor.

**Name it outside the glob** (`watch:app:client`), and let whoever is actually editing client C++ run it in its own terminal. If it must join `yarn dev`, that is a deliberate decision to make `yarn dev` require Visual Studio, and it should be written down.

### 6.2 The nodemon invocation, verified field by field

Mirroring `packages/apps/server/package.json:6`, all confirmed against nodemon's own docs and source:

- `-w ./packages/apps/client` — watch paths resolve via `path.resolve(process.cwd(), rule)`, i.e. **against the process cwd, not the config file's directory** (`lib/monitor/match.js`). Watching outside the package is fully supported. Since the script runs from the repo root, a root-relative path is correct.
- `-e "*"` — matches the server script. Nodemon strips `*` from the extension list entirely (`lib/config/exec.js`: `extension.match(/[^,*\s]+/g)`), so the net effect is **no extension filter**. Quote it, or the shell expands it.
- `-d 1` — **CLI `--delay` is in seconds; the `nodemon.json` `delay` field is in milliseconds.** Both from the README ("If you are setting this value in `nodemon.json`, the value will always be interpreted in milliseconds"). One second debounces a multi-file save into one build; the server script omits it because `cargo` is cheap to restart and a C++ link is not.
- `-x "yarn build:app:client"` — nodemon runs exec through `sh -c` on POSIX (`lib/monitor/run.js`), so `&&`, pipes and quoting all work. There is no `.js` requirement; forking only happens when the executable is literally `node`.
- `.git` needs no explicit ignore — nodemon's defaults (`ignore-by-default`) already cover `.git`, `node_modules`, `bower_components`, `.nyc_output`, `coverage`, `.sass-cache`.

### 6.3 The feedback loop, and why building to `C:` avoids it

`-e "*"` on the whole client directory will also match build output. The default `OutDir` is `$(SolutionDir)$(Configuration)\`, so an in-tree build writes `packages/apps/client/Release/TMProject.exe` — **inside the watched tree**, triggering another build, forever.

Building against a copy on `C:` sidesteps this entirely: no artifact ever lands in the watched tree. If anyone changes the design to build in-tree, `-i` on the output directories becomes mandatory, and nodemon's README warns the ignore rules match the **full absolute path**:

> "`nodemon --ignore '**/test/**'` will work, whereas `--ignore '*/test/*'` will not."

### 6.4 Killing a Windows build from Linux

Confirmed on this WSL build: SIGTERM, SIGKILL, and a process-group signal all reap the Windows child. Interop children appear as `/init` wrappers, so signals land on `/init` and propagate. nodemon kills the whole subtree — `lib/monitor/run.js` walks it with `psTree` and signals every PID, then polls until it drains — so both nodemon restarts and `concurrently --kill-others-on-fail` will terminate a running `MSBuild.exe`.

Two caveats worth carrying:

- The support is thin by Microsoft's own wording. The only official statement is <https://learn.microsoft.com/en-us/windows/wsl/release-notes>, Build 17017: "**Limited support for termination of console apps invoked via interop [GH 1614]**." The limits are undocumented, and the tracking issues (#1614, #2151, #3760) were **stale-bot-closed, not fixed** — #3760 specifically reports that the *first* interop process in a session survives being killed.
- **MSBuild worker nodes are a separate matter and are documented.** `-nr` defaults to True, so reused workers outlive the parent the watcher kills. `-nr:false` is not optional in a watch loop.

---

## 7. The three shapes, ranked

**A. Don't add it.** Client changes are authored in `w2-client` on Windows, per `CLAUDE.md`; Visual Studio already rebuilds on save, and MSBuild's incremental build makes a watcher mostly redundant for a 10-second full build. Cost: nothing. This is the honest default and the one to reject explicitly before choosing another.

**B. Watch ext4, build a copy on NTFS.** The recommended shape if the watcher is wanted. Watching works natively (§5.1, no polling), the build works (§3.4), no feedback loop (§6.3), and the `.exe` lands on `C:` where it must be to run anyway. Cost: an `rsync` of ~450 small files to drvfs per change, and the source of truth is duplicated. One new root script; nothing inside the submodule.

**C. Move the client clone to `/mnt/c` entirely.** The build works natively and there is no copy step, but the watcher then needs `-L` polling (§5.2), Visual Studio and the Rust/Node side both pay cross-boundary cost, and it contradicts Microsoft's guidance — <https://learn.microsoft.com/en-us/windows/wsl/filesystems>: "For the fastest performance speed, store your files in the WSL file system if you are working in a Linux command line." It also means the submodule checkout is no longer inside the repo, which breaks `git submodule update` from here.

Alternatives asked for at one line each: **watchexec** (<https://github.com/watchexec/watchexec>) is a native watcher with `--poll [INTERVAL]` and would work identically, but it is a new dependency for something nodemon 3.1.14 already does here. Running **nodemon on the Windows side** removes every boundary problem in this document and is the genuinely correct answer if client work happens on Windows — which is what `CLAUDE.md` says it does. **MSBuild's incremental build** already skips unchanged translation units, so the watcher saves a keystroke, not a compile.

---

## 8. If shape B is chosen

Root `package.json` additions (exact versions, no ranges, per `.yarnrc`):

```jsonc
"devDependencies": {
  "nodemon": "3.1.14"          // promote from @app/server; currently root-resolved only by hoisting
}
```

The `build:app:client` command needs, in order: `rsync -a --delete --exclude .git` into an NTFS scratch dir; `vswhere … -products '*'` with an **empty-output guard**; `MSBuild.exe` invoked directly with `-m -p:Platform=x86 -p:Configuration=Debug -nologo -noAutoResponse -nr:false -tl:off`. That is more than a readable one-liner, so it belongs in a small `scripts/build-client.sh` at the repo root — one new file, outside the submodule.

Before it can succeed on this machine, two things must be fixed outside this repo (§3.3, §3.5): install the **v142** build tools and the **ATL** component, and fix `#include "resource.h"` → `"Resource.h"` in `w2-client`. The second is only needed if anyone ever builds over UNC; on the NTFS copy it is invisible. It is still a latent bug and worth an upstream issue.

---

## 9. Open questions / not verified

- **No Microsoft statement exists that inotify fires for Windows-originated writes on ext4 via `\\wsl.localhost\`.** §5.1 rests on Microsoft's `plan9.md` architecture doc, the WSL source, and the measurement reproduced here. There is one unrebutted community report to the contrary in #4739. The measurement is solid; the *guarantee* is not — it is undocumented behaviour that Microsoft has never committed to.
- **The `cmd.exe` → `C:\Windows` UNC fallback is undocumented** on learn.microsoft.com. The `filesystems` page contains a dangling forward-reference ("exceptions are explained below") that is absent from the page source. Behaviour is measured, not promised.
- **Whether MSBuild/VC++ officially support building from a UNC path: no statement either way.** Not in the command-line reference, the MSBuild overview, the C++ MSBuild page, or the VC++ build docs. Only negative evidence exists (dotnet/msbuild#7001, #6310, #9033, and the open MAX_PATH issue #4200). Treat any claim of support as unsourced.
- **`wslpath` has no reference page** on learn.microsoft.com — it appears only by example on the WSL-interop page, and `-a`/`-u` are documented solely in the binary's own `--help`. There is no exit-code contract.
- **The #3760 "first interop process per session survives" edge case was not tested** — it needs a fresh WSL session and cannot be staged from inside one. If a stuck `MSBuild.exe` ever appears after a watcher restart, that is the first suspect.
- **Kill-on-restart was verified with a single-process console app**, not with a real MSBuild build in flight. `-nr:false` addresses the known part (worker nodes); an interrupted mid-link MSBuild was not exercised.
- **No quantified performance figure for `\\wsl.localhost\` throughput** exists in the docs — only relative claims, including the notable one at <https://learn.microsoft.com/en-us/windows/wsl/compare-versions>: "if you are using Windows applications to access Linux files, you will currently achieve faster performance with WSL 1."
- **Whether 9p `Tlock` is issued by `p9rdr.sys` for Win32 lock requests is undocumented.** The Linux-side server implements `Lock`/`GetLock` as no-ops with a `TODO: Implement server-side locks` comment (`src/linux/plan9/p9file.cpp`). Design against cross-boundary file locks being enforced in either direction — relevant if a Windows build and a Linux tool ever touch the same file concurrently.
- **The full build was never run to completion over UNC**, only to the second case-sensitivity failure. Whether further problems lurk past `resource.h` is unknown — and moot, since the recommendation avoids that path.

---

# Follow-up: can the client be built *entirely* inside WSL2, with no Windows-side MSBuild?

Date: 2026-08-12. Follow-up to §§1–9 above, which established that a Windows MSBuild cannot reach the
client on ext4 (case-sensitivity, §3) and that moving to `/mnt/c` kills Linux inotify (§5.2). If a
Linux-hosted toolchain can emit the Windows `.exe`, that entire dilemma disappears and nodemon becomes
a one-liner watching ext4 natively.

Everything marked **MEASURED** was run against the pinned submodule on this machine. Everything else is
quoted from the source that owns it. §10.8 lists what could not be verified.

## Verdict up front

> **Executed and confirmed — see §11.** This section was a prediction; §11 records the build actually
> running. The verdict held (`Release/TMProject.exe` was produced on ext4 with zero `w2-client` edits),
> but the §10.3 recipe needed four corrections. **§11 is the recipe that works; §10.3 is kept as the
> reasoning that got there.**

**Yes, with caveats — via `msvc-wine`, and the decider is not what the question assumed.**

The question assumed D3DX9 would kill it. It does not: mingw-w64 ships the full `d3dx9*.h` header set
*and* import libraries for `d3dx9_24` … `d3dx9_43` (§10.2). The thing that actually decides the answer is
much duller:

> **Wine gives you case-insensitive path resolution *and* the real MSVC toolchain, so the client builds on
> ext4 with zero changes to `w2-client`. Every non-MSVC route needs source edits in the submodule that
> `CLAUDE.md` forbids this repo from making.**

| Route | Compiler | Builds `.vcxproj`? | Links the vendored `d3dx9.lib`? | `w2-client` edits needed | Verdict |
| --- | --- | --- | --- | --- | --- |
| **msvc-wine** | real MSVC v142 under Wine | **yes** (ships an MSBuild wrapper) | yes — same linker as today | **none** | **recommended** |
| clang-cl + lld-link | clang-cl (MSVC ABI) | no — hand-rolled ninja/CMake | yes | 11 case fixes (§10.6) | viable #2 |
| mingw-w64 cross | GCC (Itanium ABI) | no | **no — hard blocker** | a real port | **dead** |

The single thing that kills mingw-w64 is *not* D3DX availability. It is that
`Dependencies/Directx/Lib/d3dx9.lib` is a **static MSVC library from 2002** — 205 `obj/i386/*.obj`
members, 8414 MSVC-mangled `??…` symbols, referencing `__CxxFrameHandler` and `_except_handler3`
(**MEASURED**, §10.1). GCC cannot link that at any price. Switching to mingw's DLL-model D3DX then
breaks the source (§10.2), and 111 `sprintf_s` call sites stop compiling (§10.3) — on top of 116,597
lines of decompiled MSVC C++ that has never seen GCC. That is the "possible in principle after a real
port" case, i.e. **no**.

---

## 10.1 What is actually vendored: the original December-2002 DirectX 9.0 SDK

The brief assumed the June 2010 SDK (`D3DX_SDK_VERSION 43`, thin import lib + `d3dx9_43.dll`). It is not
that. **MEASURED**:

```
Dependencies/Directx/Include/d3dx9core.h:25-26   #define D3DX_VERSION 0x0900
                                                 #define D3DX_SDK_VERSION 9
Dependencies/Directx/Include/d3d9.h:27           #define D3D_SDK_VERSION 31
```

`D3DX_SDK_VERSION 9` is the **original** DirectX 9.0 SDK. In that release D3DX was a *static* library, and
the vendored `d3dx9.lib` (4.3 MB) proves it — `ar t` lists 205 real object files, not import thunks:

```
$ ar t Dependencies/Directx/Lib/d3dx9.lib | head -4
obj/i386/pchcore.obj
obj/i386/init.obj
obj/i386/d3dx9dbg.obj
obj/i386/cbuffer.obj
$ strings -a … | grep -c '^??'      # MSVC-mangled C++ symbols
8414
$ strings -a … | grep -oE '__CxxFrameHandler|_except_handler3' | sort -u
__CxxFrameHandler
_except_handler3
```

Contrast `d3d9.lib`, whose every member is the string `d3d9.dll` — that one *is* an import lib.
`obj/i386/` also settles the architecture question independently of the `.sln`: **x86 only**.

Microsoft documents the static→DLL transition at
<https://learn.microsoft.com/en-us/windows/win32/dxtecharts/directx-setup-for-game-developers>:

> "In the past, the optional components of the DirectX SDK, including D3DX, were released as static
> libraries. However, these are now released as dynamic-like libraries (DLL) because of the increased
> demand for better security practices."

and the current model at <https://learn.microsoft.com/en-us/windows/win32/direct3d9/d3dx>:

> "D3DX is provided as a dynamic-link library (DLL)." … "By statically linking an application to
> D3dx9.lib, the application dynamically links to the corresponding retail D3DX DLL at run-time."
> … "**Note** — The D3DX library is deprecated."

**Three consequences that drive everything below.**

1. `TMProject.exe` is today **self-contained**: D3DX is compiled into it. Any route that moves to the DLL
   model changes the client's deployment contract — the `.exe` starts requiring `d3dx9_43.dll` beside it.
2. Linking a 2002 MSVC static archive requires an **MSVC-ABI linker**. `link.exe` (msvc-wine) and
   `lld-link` (clang-cl) qualify; GNU `ld` does not.
3. `<ImageHasSafeExceptionHandlers>false</ImageHasSafeExceptionHandlers>`
   (`Projects/TMProject/TMProject.vcxproj:145`) exists precisely because those ancient objects carry no
   SAFESEH table. Keep it on any MSVC-ABI route.

## 10.2 mingw-w64 *does* ship D3DX9 — and it still does not help

Correcting the brief's premise. From the mingw-w64 tree:

- Headers `d3dx9.h`, `d3dx9core.h`, `d3dx9math.h`/`.inl`, `d3dx9mesh.h`, `d3dx9tex.h`, `d3dx9effect.h`,
  `d3dx9anim.h`, `d3dx9shader.h`, `d3dx9shape.h`, `d3dx9xof.h` are all in
  <https://github.com/mingw-w64/mingw-w64/tree/master/mingw-w64-headers/include> (Wine-derived).
- `mingw-w64-crt/Makefile.am` builds them:
  `d3dx9=d3dx9_43`, `dx32_DATA = … libd3dx9.a`, `lib32/libd3dx9.a: lib32/$(d3dx9).def`
  — <https://raw.githubusercontent.com/mingw-w64/mingw-w64/master/mingw-w64-crt/Makefile.am>
- `mingw-w64-crt/lib32/d3dx9_43.def` (`LIBRARY "d3dx9_43.dll"`, ~470 stdcall exports, gendef-dumped from
  the real Microsoft DLL), plus `d3dx9_24.def` … `d3dx9_42.def`. `d3dx9_22`/`_23` are absent — those
  predate the DLL switch, matching §10.1.
- Confirmed in a shipped distro: `/usr/i686-w64-mingw32/lib/libd3dx9.a`, `libd3dx9_43.a`, `libd3dx9_24.a`…
  — <https://packages.debian.org/sid/all/mingw-w64-i686-dev/filelist>

Everything else the project links is also present in stock mingw-w64: `d3d9.def`, `dinput.def`/
`dinput8.def`, `dsound.def`, DirectShow (`dshow.h`, `strmif.h`, `control.h`), static `libstrmiids.a` and
`libdxguid.a` (`mingw-w64-crt/libsrc/strmiids.c`, `dxguid.c`), and `iphlpapi`/`wininet`/`wsock32`/
`ws2_32`/`imm32`/`winmm`/`odbc32`/`odbccp32`/`winspool`/`comdlg32`/`oleaut32`/`uuid`.

**So why is it still dead?** Three independent blockers, in order of severity.

**(a) The vendored static lib is unlinkable by GCC.** §10.1. Not fixable — it is an ABI wall, not a flag.

**(b) Moving to mingw's D3DX breaks the source.** mingw's `d3dx9core.h` is `D3DX_SDK_VERSION 43`, and
`ID3DXSprite` changed vtable between SDK 9 and SDK 43. mingw
(<https://raw.githubusercontent.com/mingw-w64/mingw-w64/master/mingw-w64-headers/include/d3dx9core.h>):

```
STDMETHOD(Begin)(THIS_ DWORD flags) PURE;
STDMETHOD(Draw)(THIS_ struct IDirect3DTexture9 *texture, const RECT *rect,
    const D3DXVECTOR3 *center, const D3DXVECTOR3 *position, D3DCOLOR color) PURE;
```

vendored SDK 9 (`Dependencies/Directx/Include/d3dx9core.h:223-234`): `Begin(THIS)` — no argument — and a
seven-parameter `Draw` taking `D3DXVECTOR2` scaling/rotation-centre plus a `FLOAT Rotation`. The client
uses the old shape (**MEASURED**):

```
Projects/TMProject/RenderDevice.cpp:1905   m_pSprite->Begin();
Projects/TMProject/RenderDevice.cpp:1906   m_pSprite->Draw(pTexture, &srcRect, &scaleVec, &rotCenter, 0, &destPoint, 0xFFFFFFFF);
Projects/TMProject/RenderDevice.cpp:2771-2772   (the same pair, with -fAngle)
```

Six lines — small, but they are a *rendering* rewrite (2-D scale/rotate must move into a transform
matrix), and they must land in `w2-client`. `ID3DXFont` is only used for `OnLostDevice`/`OnResetDevice`,
which are identical in both, and `ID3DXBuffer` is unchanged.

**(c) 111 `sprintf_s` call sites stop compiling.** The client uses MSVC's C++ array-size-deducing
overload (**MEASURED** — 111 of 138 `sprintf_s` calls pass a format string as the *second* argument, e.g.
`sprintf_s(szTextureName, "%s", szTemp)`). mingw-w64 does not provide it:
<https://raw.githubusercontent.com/mingw-w64/mingw-w64/master/mingw-w64-headers/crt/sec_api/stdio_s.h>
declares only `__mingw_ovr int __cdecl sprintf_s(char *_DstBuf, size_t _DstSize, const char *_Format, ...)`
and the word `template` does not occur in the file. `_mingw_secapi.h` defines
`_CRT_SECURE_CPP_OVERLOAD_SECURE_NAMES` but its only template-generating macro is the *memory* one
(`__CRT_SECURE_CPP_OVERLOAD_STANDARD_NAMES_MEMORY_0_3_`), which defaults to 0. `fopen_s` (45 sites) and
`sscanf_s` (10) pass explicit arguments and are fine.

**The good news nobody expected.** These sources are *unusually* portable for decompiled MSVC output.
**MEASURED** across all 109 `.cpp` and 128 `.h` in `Projects/TMProject`:

| Construct | Count |
| --- | --- |
| `__try` / `__except` / `__finally` (SEH) | **0** |
| `__asm` / `_asm` (MSVC inline assembly) | **0** |
| `__declspec` | **0** |
| `__uuidof`, `#import`, `__super`, `__if_exists`, `__interface` | **0** |
| MSVC intrinsics (`__debugbreak`, `_ReturnAddress`, `__cpuid`, `_BitScan`, …) | **0** |
| `__forceinline` / `__fastcall` / `declspec(naked)` | **0** |
| `#pragma pack` | **0** |
| MFC / ATL includes | **0** |
| `#pragma warning` | 2 (`pch.h:17`, `pch.h:21`) |
| `#pragma comment(lib, …)` | 2 (`pch.h:31-32` — `IPHLPAPI.lib`, `Strmiids.lib`) |
| `__int64` | 8 (mingw defines it: `#define __int64 long long`, `crt/_mingw.h.in`) |
| `_stricmp` | 3 (mingw has it) |
| `std::` usage of any kind | 1 (`std::chrono`) |

The classic hard blockers for decompiled MSVC code — inline asm and SEH — are **completely absent**. The
project is already compiled with `/permissive-` and `/std:c++17` (`ConformanceMode`, `LanguageStandard`
in `TMProject.vcxproj`), so it is closer to standard C++ than its provenance suggests. mingw-w64 is a
*port*, not an impossibility. It is simply weeks of work with no advantage over routes that keep MSVC.

**Also note the ATL claim in §3.5 was a red herring.** The only `atl` occurrences in the entire submodule
are the README's install instruction (`README.md:18`) and a comment in an unused DirectX header
(**MEASURED**). No source includes ATL, and §3.4's successful NTFS build happened on a machine with no
`atlmfc` directory — which settles it empirically. Do not install ATL on account of the client.

## 10.3 msvc-wine — the recommended route

> **Superseded by §11 for the commands.** The route is correct and was carried out end to end, but four
> of the steps below are wrong as written. Use §11's recipe; read this section for *why* each piece is
> there.

<https://github.com/mstorsjo/msvc-wine> downloads the genuine Microsoft toolchain using Visual Studio's
own installer manifests and runs it under Wine on Linux.

**It ships MSBuild.** This is the finding that makes it the answer, and the README does not mention it —
the repo does. `vsdownload.py` has `--with-msbuild` ("Include MSBuild (default)", packages
`Microsoft.Build` + `Microsoft.Build.Dependencies`); `wrappers/` contains `msbuild` and `msbuild.exe`
alongside `cl`, `link`, `lib`, `rc`, `mt`, `mc`, `midl`, `ml`, `nmake`, `dumpbin`
(<https://github.com/mstorsjo/msvc-wine/tree/master/wrappers>); and `test/test-msbuild.sh` builds a real
`test/HelloWorld.vcxproj` — a genuine `Microsoft.Cpp.props`/`.targets` project with `Debug|Win32` and
`Release|Win32` — for both configurations × `UseEnv=true/false`. **`TM.sln` can be driven as-is.**

**It installs the toolset the project pins.** `--msvc-version` selects a specific MSVC; the version table
in `vsdownload.py` maps `16.11 → 14.29`, i.e. **v142**. `--sdk-version` pins Windows SDK 10. msvc-wine's
CI runs `./vsdownload.py --accept-license --major 16` and `--major 16 --msvc-version 16.9` on every push,
each followed by a real `cl test/hello.c` — current, green evidence that the VS2019 manifests still
resolve (<https://github.com/mstorsjo/msvc-wine/blob/master/.github/workflows/build.yml>). **§3.5's
"v145 only" machine-local blocker therefore disappears**: this route installs v142 regardless of what
Windows has.

**It solves case-sensitivity twice over.** `install.sh` runs two Perl scripts: `lowercase -symlink` (adds
lowercase symlinks *alongside* the originals, so both spellings resolve) and `fixinclude` (rewrites
`#include` directives inside the SDK headers to lowercase and forward slashes), across `include`,
`atlmfc/include`, and every Windows SDK `include`/`lib` directory. It also adds uppercase `.lib` aliases
and `kits`→`Windows Kits` directory links. But the comment at `install.sh:136` is the important one:

> "Lowercase the SDK headers and libraries. **As long as cl.exe is executed within wine, this is mostly
> not necessary.**"

That is msvc-wine's own statement that **Wine's path layer resolves case-insensitively**. If it holds for
the project tree on ext4 as well as for the SDK, then §3.2 (MSBuild lowercasing its intermediate path),
§3.3 (`#include "resource.h"` vs `Resource.h`) and all of §10.6 simply do not fire, and the client builds
**with zero `w2-client` changes**. This is the highest-value thing to test first — see §10.8.

**What it needs on the Linux side.** README: `apt-get install -y wine64 python3 msitools ca-certificates
winbind` (`winbind` is required for `/Zi` + `/FS`, i.e. `mspdbsrv.exe`; without it you get
`fatal error C1902: Program database manager mismatch`). MSBuild additionally needs **wine-mono** —
`test/test.sh`: "MSBuild requires .NET framework v4.x or Mono to run." CI installs
`wine-mono-8.1.0-x86.msi` and enables `dpkg --add-architecture i386` + `wine32` for it. **32-bit Wine is
not needed for the compiler itself**: `msvcenv.sh` sets `BINDIR=…/bin/Hostx64/$ARCH`, so an x86 target is
built by the 64-bit cross `cl.exe` under `wine64`.

Concrete shape (this repo would keep it in a root `scripts/build-client.sh`, per §8 — nothing goes inside
the submodule):

```bash
# one-time, per machine
git clone https://github.com/mstorsjo/msvc-wine ~/msvc-wine
~/msvc-wine/vsdownload.py --accept-license --major 16 --msvc-version 16.11 --dest ~/msvc
~/msvc-wine/install.sh ~/msvc
wine msiexec /i wine-mono-8.1.0-x86.msi          # required for MSBuild only

# once per shell session — avoids paying wineserver startup on every cl.exe
wineserver -k; wineserver -p; wine wineboot

# the build
~/msvc/bin/x86/msbuild /home/nrechdan/projects/w2-server/packages/apps/client/TM.sln \
  -p:Platform=x86 -p:Configuration=Release -m -nr:false -noAutoResponse -tl:off -v:m
```

Every MSBuild switch is the one §4.4 already argued for, and for the same reasons.

**Caveats, all from the repo itself.**

- **Not redistributable.** README: "This downloads and unpacks the necessary Visual Studio components
  using the same installer manifests as Visual Studio 2017/2019's installer uses. Downloading and
  installing it requires accepting the license… **As Visual Studio isn't redistributable, the installed
  toolchain isn't either.**" Their CI repeats it: "Intentionally not storing any artifacts with the
  downloaded tools; the installed files aren't redistributable!" **You cannot bake this into a shared CI
  or Docker image.** Every machine downloads its own copy, several GB.
- **`--major 16` + MSBuild is not CI-covered.** msvc-wine's CI exercises `--major 16` with `cl` only, and
  MSBuild only against current VS. `wrappers/msbuild` hardcodes `VCInstallDir_180`,
  `VCToolsInstallDir_180` and points at `MSBuild/Microsoft/VC/v170`; a VS2019 layout will need those env
  names adjusted. **This is the main unverified risk in the recommended route.**
- **Release is the happy path.** README on Debug builds: "Yes, but there may be troubles. From wine errors
  appearing in the logs/console to problems when trying to launch it because of missing debug
  redistributables… For the best out-of-the-box experience build in Release mode." That happens to match
  the client's own CI (§1.1) and §1's `Release/` output path.
- **Headless is fine** — `wine-msvc.sh` sets `WINEDEBUG=-all` and the Dockerfile runs `wineboot --init`
  with no X.
- **No performance figure exists** in the repo or README. Wine overhead on a ~10 s build (§3.4) is
  unquantified.

## 10.4 clang-cl + lld-link — viable second choice, no Wine at all

Keeps the MSVC ABI (so the vendored static `d3dx9.lib` links) without running anything under Wine. Use
msvc-wine's `vsdownload.py` + `install.sh` purely as a *header/library fetcher* — its
`lowercase`/`fixinclude` passes exist specifically so clang-cl works on the same tree — then compile
natively. msvc-wine's own `Dockerfile.clang` and `test/test-clang-cl.sh` do exactly this in CI.

Why the client is a good fit: clang's documented weak spots are the ones this codebase does not have.
<https://clang.llvm.org/docs/MSVCCompatibility.html> flags SEH as only *Partial* —

> "**Asynchronous Exceptions (SEH)**: Partial. Structured exceptions (`__try` / `__except` / `__finally`)
> mostly work on x86 and x64. LLVM does not model asynchronous exceptions, so it is currently impossible
> to catch an asynchronous exception generated in the same frame as the catching `__try`."

— and warns that "Clang follows the GCC model for intrinsics and not the MSVC model." The client has
**zero** SEH and **zero** intrinsics (§10.2), so neither applies. C++ exceptions are "Mostly complete…
implemented for x86 and x64"; record layout and RTTI are "Complete".

`lld-link` handles the rest — <https://lld.llvm.org/windows_support.html>: "Linking against static
library — Done. The format of static library (.lib) on Windows is actually the same as on Unix (.a). LLD
can read it."; "Safe Structured Exception Handler (SEH) — Done for both x86 and x64."; "Windows resource
files support — Done." And `-fms-extensions` / `-fms-compatibility` are **on by default for Windows
targets**, with `#pragma comment(lib)` explicitly called out as "well supported"
(<https://clang.llvm.org/docs/UsersManual.html>) — so `pch.h:31-32` still auto-links IPHLPAPI and
Strmiids. `-fms-compatibility` also implies `-fno-strict-aliasing` and `-fwrapv`, both quietly welcome in
decompiled code.

Sysroot flags, verbatim from `clang-cl /?` as printed in the Users Manual (they appear **only** there —
`ClangCommandLineReference.html` has zero hits for them):

```
/vctoolsdir <dir>       Path to the VCToolChain
/vctoolsversion <value> For use with /winsysroot, defaults to newest found
/winsdkdir <dir>        Path to the Windows SDK
/winsdkversion <value>  Full version of the Windows SDK, defaults to newest found
/winsysroot <dir>       Same as "/diasdkdir <dir>/DIA SDK" /vctoolsdir <dir>/VC/Tools/MSVC/<vctoolsversion> "/winsdkdir <dir>/Windows Kits/10"
```

**What it costs.** Three things.

1. **You lose the `.vcxproj`.** There is no Linux MSBuild that can build C++: the `Microsoft.Cpp.*`
   props/targets ship inside a Visual Studio install, not the .NET SDK, and dotnet/msbuild's own README
   says its bootstrap MSBuild "may not work for all scenarios, **including C++ builds**"
   (<https://github.com/dotnet/msbuild#readme>). Clang's MSBuild integration
   (`/p:PlatformToolset=LLVM`, `/p:CLToolExe=clang-cl.exe`) is Windows-only. You would hand-roll ninja or
   CMake for 109 translation units and keep it in sync with the `.vcxproj` by hand — or in `w2-client`,
   which is a bigger conversation.
2. **The 11 case fixes in §10.6 become mandatory.** clang does exact-case lookup and msvc-wine's
   `lowercase -symlink` only covers the SDK tree, not the client's own sources or the vendored DX
   headers. (And it would not even help there: the sources ask for `<Dshow.h>` while disk has `DShow.h` —
   lowercasing adds `dshow.h`, which is a third spelling.)
3. **`-Werror=unknown-argument` from day one.** "Options that are not known to clang-cl will be ignored by
   default" — silently. `SDLCheck` (`/sdl`) is exactly such an option.

## 10.5 Resource compilation is not a problem

`Projects/TMProject/TMProject.rc` — 179 lines, **UTF-16LE with BOM** (**MEASURED**: `file` reports
"Unicode text, UTF-16, little-endian"). It uses only `ICON`, `CURSOR`, `MENU`, `ACCELERATORS`,
`DIALOGEX`, `STRINGTABLE`, `TEXTINCLUDE`, two `LANGUAGE` blocks (en-US and pt-BR), and includes
`resource.h`, `targetver.h`, `windows.h`. **No `afxres.h`, no `winres.h`, no MFC resource types.**
Referenced assets all exist with matching case: `TMProject.ico`, `small.ico`,
`Resources\CursorGroup162.cur`, `Resources\CursorGroup164.cur` (**MEASURED**).

Both MSVC-ABI routes get a real `rc.exe`: msvc-wine ships an `rc` wrapper pointing at the SDK binary.
LLVM's `llvm-rc` is the fallback — note it has **no documentation on llvm.org**
(`llvm.org/docs/CommandGuide/llvm-rc.html` is a 404 and it is absent from the CommandGuide index); its
only compatibility claim lives in the source header, "This is intended to be a platform-independent port
of Microsoft's rc.exe tool" (`llvm/tools/llvm-rc/llvm-rc.cpp`). GNU `windres` is the weakest option here
— UTF-16 `.rc` input is its classic failure mode — but no route above needs it.

## 10.6 The full case-mismatch list — 11 sites, not 3

> **Wrong in both directions — superseded by §11.6.** This list assumed every Windows SDK header
> is lowercase on disk. It is not: the SDK really ships `Windows.h`, `WinSock2.h` and `WinInet.h`
> mixed-case, so five of the eleven entries below flag **correct** code, and "fixing" them would
> break it. The lowercase spellings that made them look wrong were symlinks created by
> msvc-wine's `install.sh`, not shipped by Microsoft. The list also **misses** five real sites.
> §11.6 has the verified list, produced mechanically rather than by reading.

§3.3 found one (`resource.h`) by scanning quoted includes. A complete scan of quoted **and**
angle-bracket includes finds **eleven** sites. Note that `grep` without `-a` silently skips `NewApp.cpp`
here, which is how §3.3 missed two of them; the list below is `grep -a` (**MEASURED**).

Quoted — on disk the file is `Projects/TMProject/Resource.h`:

```
Projects/TMProject/TMProject.h:3    #include "resource.h"
Projects/TMProject/NewApp.cpp:19    #include "resource.h"
Projects/TMProject/TMProject.rc:3   #include "resource.h"
```

Angle-bracket, uppercase — every Windows SDK, mingw-w64 and vendored-DX header on disk is lowercase
(`d3d9.h`) or differently-cased (`DShow.h`), so all eight fail an exact-case lookup:

```
Projects/TMProject/pch.h:7             #include <Windows.h>
Projects/TMProject/pch.h:20            #include <Dshow.h>        ← disk: DShow.h
Projects/TMProject/targetver.h:6       #include <SDKDDKVer.h>
Projects/TMProject/CPSock.cpp:3        #include <WinSock2.h>
Projects/TMProject/D3DEnumeration.cpp:8 #include <D3D9.h>        ← disk: d3d9.h
Projects/TMProject/NewApp.cpp:17       #include <WinInet.h>
Projects/TMProject/TMFieldScene.cpp:56 #include <WinInet.h>
Projects/TMProject/Basedef.cpp:6       #include <WinInet.h>
```

No other quoted include mismatches exist (**MEASURED**, scan of every `#include "…"` against every
filename in `Projects/TMProject` and `Dependencies/Directx/Include`).

These are latent bugs worth an upstream issue in `w2-client` regardless of which route wins — eleven
one-word edits. **The recommended route (§10.3) does not require them**, because Wine resolves case
insensitively; clang-cl does.

## 10.7 What this means for the watcher

If §10.3 works, §§3, 5.2, 6.3 and 8 of this document are all superseded and the recommendation in §7
changes from **B** ("watch ext4, build a copy on NTFS") to a plain in-place build:

```jsonc
// root package.json — still NOT dev:app:client (§6.1 stands unchanged)
"watch:app:client": "nodemon -w ./packages/apps/client -e \"*\" -d 1 -i \"packages/apps/client/**/Release/**\" -i \"packages/apps/client/**/Debug/**\" -x \"yarn build:app:client\""
```

No `rsync`, no `/mnt/c`, no `vswhere`, no `wslpath`, no duplicated source of truth, native inotify (§5.1).
**But** the build output now lands *inside* the watched tree (`packages/apps/client/Release/`, §1.1), so
the feedback loop of §6.3 comes back and the `-i` rules become mandatory — and per nodemon's README they
match the **full absolute path**, so `**/` prefixes are required.

Everything in §2 still binds: nothing may be added inside the submodule, so the toolchain bootstrap and
the build script live at the repo root.

And §7A still stands, now with a bigger price tag. This is a multi-gigabyte, per-machine,
non-redistributable Visual Studio install plus Wine and wine-mono, to serve a workflow `CLAUDE.md` says
should be happening in the `w2-client` repo on Windows. **Decide whether the watcher should exist before
paying for it.**

## 10.8 Open questions / not verified — follow-up

- **Wine's case-insensitive path resolution was not tested against this tree.** The whole "zero
  `w2-client` changes" claim rests on `install.sh:136`'s parenthetical ("As long as cl.exe is executed
  within wine, this is mostly not necessary") plus Wine's general behaviour. Note the hedge in that
  sentence: *mostly*. **Test this first**: install msvc-wine, run `cl.exe` on a one-line TU that does
  `#include "resource.h"` from the client directory on ext4. If it fails, the recommended route inherits
  clang-cl's §10.6 cost and the verdict weakens to "yes, after 11 upstream edits".
- **`--major 16` (v142) together with MSBuild is not covered by msvc-wine's CI**, and
  `wrappers/msbuild` is written against a current-VS layout (`VCInstallDir_180`, `MSBuild/Microsoft/VC/v170`).
  Whether `TM.sln` builds through it unmodified is unknown.
- **Nothing was built.** No toolchain is installed on this machine (**MEASURED**: `mingw-w64`, `clang`,
  `lld`, `wine` all absent; the apt candidates exist but installing them is not a cheap smoke test).
  Every claim above is from headers, manifests, source and documentation — not from a compile.
- **Whether the 116,597 lines compile clean under clang-cl was not tested.** The construct census in
  §10.2 says the *known* hard blockers are absent; it cannot say there are no unknown ones. Expect a
  first-run diagnostic pile of unknown size.
- **`llvm-rc`'s compatibility with MS `rc.exe` has no primary documentation** — no page on llvm.org, only
  a source-file comment. Its handling of this specific UTF-16 `.rc` is untested.
- **Whether mingw-w64's Wine-derived D3DX9 headers cover every API the client calls** was not checked
  beyond `ID3DXSprite`/`ID3DXFont`/`ID3DXBuffer`. Moot — the route is dead for other reasons.
- **The February-2005 date for the D3DX static→DLL switch could not be sourced to a live first-party
  Microsoft page.** The undated "were released as static libraries / are now released as DLLs" passage
  quoted in §10.1 is first-party; the specific release is corroborated only by the mingw-w64 `.def` range
  starting at 24 and by secondary release-note quotes.
- **No performance comparison exists** between MSBuild-under-Wine on ext4 and MSBuild-on-NTFS (§3.4's
  ~10 s). Neither msvc-wine nor Wine publishes one.

---

# 11. Executed: the client builds on ext4, entirely inside WSL2

Date: 2026-08-12. §10 was research; this section is the record of running it. Everything here is
**MEASURED** on this machine unless said otherwise.

## 11.1 Result

`packages/apps/client/Release/TMProject.exe` — `PE32 executable for MS Windows 6.00 (GUI), Intel i386,
5 sections`, 1,666,560 bytes, 0 errors, exit 0. Built from ext4 by MSVC 14.29.30133 (**= v142**, the
toolset `TMProject.vcxproj` pins) running under Wine 10.0. No Windows-side MSBuild, no `/mnt/c`, no
`\\wsl.localhost\`.

**§10.8's highest-value open question is resolved: Wine's case-insensitivity holds for the project tree
on ext4, not just for the SDK.** A one-TU test compiling `#include "resource.h"` against an on-disk
`Resource.h` returned exit 0, as did `<Windows.h>`, `<WinInet.h>` and `<SDKDDKVer.h>`. **All 11 sites in
§10.6 are moot for this route — zero `w2-client` edits were needed.** They remain real bugs for
clang-cl (§10.4) and worth an upstream issue regardless.

Timings, `Release|x86` (**MEASURED**): full build from an empty intermediate directory **24.9 s** for
109 translation units; incremental after invalidating one object ~7–8 s (recompile + LTCG "Generating
code" + relink, exe mtime confirmed to move). §10.3's "no performance figure exists" is now answered for
this repo.

An earlier draft of this section said "full build ~2 min". That number was never measured — it was
inferred from wall-clock between task notifications, which included unrelated work. The 24.9 s figure
is `time` around `scripts/build-client.sh` with both `Release/` directories deleted first. Note it does
**not** include Wine prefix initialisation, which a genuinely first-ever run on a fresh machine pays
once.

## 11.2 Four corrections to §10.3

1. **`--major 16` does not ship the MSBuild engine.** It installs the v160 props/targets and
   `Microsoft.Build.CPPTasks.Common.dll`, but no `MSBuild.exe` and no `Microsoft.Build*.dll` — the
   `Microsoft.Build` / `Microsoft.Build.Dependencies` packages `vsdownload.py:330-331` requests do not
   exist in the VS2019 manifest. The wrapper then dies with
   `wine: failed to open ".../MSBuild/Current/Bin/amd64/MSBuild.exe": c0000135`. Fix: a second
   `vsdownload.py` run against the **VS2022** manifest with everything but MSBuild disabled — 31.9 MB, not
   another 4.5 GB — unpacked into the same `--dest`.
2. **wine-mono must land at exactly `c:\windows\mono\mono-2.0`.** The `.tar.xz` extracts to a
   `wine-mono-9.4.0/` top-level directory; leaving that name gives
   `err:mscoree:CLRRuntimeInfo_GetRuntimeHost Wine Mono is not installed` and a silent exit 255. Renaming
   the directory to `mono-2.0` fixes it. The tarball also avoids §10.3's `dpkg --add-architecture i386` +
   `wine32`, which are only needed to run the `.msi`. Wine 10.0 pairs with wine-mono 9.4.0, not 8.1.0.
3. **The `_180` env-name risk §10.3 flagged is real.** `wrappers/msbuild` exports `VCInstallDir_180` /
   `VCToolsInstallDir_180`; the v160 props shipped by `--major 16` read `VCInstallDir_160` /
   `VCToolsInstallDir_160` (**MEASURED**: 13 and 8 references respectively across
   `MSBuild/Microsoft/VC/v160/*.props|*.targets`, and zero `_180` references). Both must be exported.
4. **`$(VCTargetsPath)` must be overridden.** Because the engine is now VS2022, it defaults to
   `MSBuild\Microsoft\VC\v170\`, which this install does not have:
   `error MSB4019: The imported project "…\v170\Microsoft.Cpp.Default.props" was not found`. Point it at
   `…\v160\`.

Two smaller things:

- **The solution's platform is `x86`, not `Win32`.** `-p:Platform=Win32` fails at solution level with
  `error MSB4126: The specified solution configuration "Release|Win32" is invalid`. `TM.sln`'s
  `SolutionConfigurationPlatforms` declares `Debug|x64 Debug|x86 Release|x64 Release|x86`, and
  `Release|x86` maps to the project's `Release|Win32`. §10.3's `-p:Platform=x86` was right.
- **`-tl:off` is unnecessary** and was dropped; output is already plain under `WINEDEBUG=-all`.

## 11.3 A new hazard §10 did not find: the vendored DirectX headers shadow the SDK

Putting `Dependencies/Directx/Include` **ahead** of the Windows SDK on the include path breaks
`<windows.h>` itself:

```
kits/10/include/10.0.19041.0/um/fileapi.h(1212): error C2146: syntax error: missing ')' before identifier 'aSegmentArray'
kits/10/include/10.0.19041.0/um/fileapi.h(1212): error C2081: 'FILE_SEGMENT_ELEMENT': name in formal parameter list illegal
```

Cause (**MEASURED**): the 2002 SDK vendors its own `basetsd.h`, which contains no `POINTER_64` and no
`PVOID64` definition, and it shadows the SDK's `shared/basetsd.h`. `winnt.h:13415` then fails to declare
`typedef union _FILE_SEGMENT_ELEMENT { PVOID64 Buffer; … }`, and `fileapi.h` cascades. Removing the
vendored directory from the include path makes the identical TU compile clean.

This is **ordering-dependent, and the `.vcxproj` is inconsistent about it** (**MEASURED**, per
`PropertyGroup` condition):

| Configuration | First entry on `IncludePath` | Safe? |
| --- | --- | --- |
| (no condition) | `$(IncludePath)` | yes |
| `Release\|Win32` | `$(IncludePath)` | **yes — the config we build** |
| `Debug\|x64` | `$(SolutionDir)Dependencies\Directx\Include` | **no** |
| `Release\|x64` | `$(DXSDK_DIR)include` | depends on an unset env var |

`Release|Win32` is safe by luck, not design. **Do not switch this build to `Debug|x64` without fixing the
ordering upstream first.** Independent of §10.3's separate point that Release is msvc-wine's happy path.

## 11.4 What landed in the repo

Per §2 and §8, nothing inside the submodule:

- `scripts/build-client.sh` — sources msvc-wine's own `bin/x86/msvcenv.sh` for `BASE` / `MSVCBASE` /
  `MSVCDIR` rather than hardcoding them, applies corrections 3 and 4, globs `MSBuild/Microsoft/VC/v1*/`
  so it does not hardcode `v160`, and honours `MSVC_ROOT` (default `~/msvc`). Setup commands live in its
  header comment.
- `package.json` — `build:app:client` calling that script, and `dev:app:client` running it under
  nodemon. `nodemon` `3.1.14` added to root `devDependencies`, exact, matching the server workspace and
  `.yarnrc`'s `--add.exact true`.

**§6.1's warning was overridden deliberately, at the user's request.** The script *is* named
`dev:app:client`, so it joins `conc --kill-others-on-fail yarn:dev:*` and runs as part of `yarn dev`.
The consequences §6.1 predicted stand: a C++ compile error now takes down the Next.js and Rust dev
servers, and `yarn dev` requires the ~4.5 GB toolchain on every machine. Renaming it out of the glob is
the one-word opt-out.

The nodemon invocation (**MEASURED** — initial build, then `restarting due to changes` and a second
successful build on touch):

```
nodemon -w "packages/apps/client/Projects" \
        -i "packages/apps/client/Projects/TMProject/Release/*" \
        -e "cpp,h,rc,vcxproj,sln" --delay 1 -x "yarn build:app:client"
```

Both filters are load-bearing. The project's intermediate directory is
`Projects/TMProject/Release/`, i.e. **inside the watched tree** — unlike the Rust server, whose
`target/` sits outside `src/`. Copying the server's `-e "*"` (`packages/apps/server/package.json:5`)
would make every build's own `.obj`/`.tlog` output retrigger the watcher forever.

## 11.5 Still not verified

- **Incremental correctness.** `touch`ing a source file did **not** cause MSBuild to rebuild (exe mtime
  unchanged after a 6.5 s no-op run); only deleting an object forced it. Note that
  `Microsoft.Build.FileTracker.Msi` was reported `Skipping unpacking … of type Msi` during download, so
  file tracking may be degraded. **A real content edit was never tested** — doing so means writing inside
  the submodule, which `CLAUDE.md` forbids from this repo. Test it from `w2-client` before relying on the
  watcher for a real edit loop; if tracking is broken, `-t:Rebuild` or deleting the intermediate directory
  is the fallback, at full-build cost.
- **Windows→ext4 inotify was not re-measured here.** §5.1's measurement stands unchallenged, but this
  session only wrote from the Linux side.
- **The produced `.exe` was never run.** It is the right architecture and links, nothing more. Whether it
  is byte-comparable to an MSVC-on-Windows build, or behaves identically, is untested.
- **Only `Release|x86` was built.** The other three configurations are untested, and §11.3 gives reason
  to expect `Debug|x64` to fail.
- **Wine 10.0 ↔ wine-mono 9.4.0 pairing was not confirmed from a primary source.** The version was chosen
  by matching release lineage after `strings` failed to find an expected version in Wine's `appwiz.cpl`
  and `mscoree`. It works; it may not be the officially paired release.

## 11.6 The case-mismatch list, corrected — 10 sites, and §10.6 had half of them wrong

§10.6 was built by reading includes and assuming the Windows SDK is lowercase on disk. **It is not.**
The SDK ships `Windows.h`, `WinSock2.h` and `WinInet.h` mixed-case (**MEASURED**, `find -type f`
excluding symlinks). What made them *look* lowercase is msvc-wine's `install.sh`, which runs
`lowercase -symlink` and adds lowercase symlinks **alongside** the real files — an artifact of our
toolchain, not of the SDK.

Consequences: §10.6 flagged **five correct sites** (`pch.h:7 <Windows.h>`, `CPSock.cpp:3 <WinSock2.h>`,
and three `<WinInet.h>`), where "fixing" the casing would have introduced the bug it claimed to remove;
and it **missed five real ones**, including three lowercase `<windows.h>` and a second mismatch in
`TMProject.rc` that a non-UTF-16-aware read never saw.

The verified list — produced by scanning every `#include` in `Projects/TMProject` against the real
filenames in the project, the vendored DirectX headers, all five Windows SDK include directories and the
MSVC include directory, with symlinks excluded and UTF-16 sources decoded (**MEASURED**):

| Site | Written | On disk |
| --- | --- | --- |
| `D3DEnumeration.cpp:7`, `DXUtil.cpp:9`, `framework.h:6`, `TMProject.rc:14` | `windows.h` | `Windows.h` |
| `NewApp.cpp:19`, `TMProject.h:3`, `TMProject.rc:3` | `resource.h` | `Resource.h` |
| `D3DEnumeration.cpp:8` | `D3D9.h` | `d3d9.h` |
| `targetver.h:6` | `SDKDDKVer.h` | `sdkddkver.h` |
| `pch.h:20` | `Dshow.h` | `DShow.h` (vendored) **and** `dshow.h` (SDK) |

`pch.h:20` was the only judgement call: it matches neither spelling, and today resolves to the **SDK's**
`dshow.h` because `Release|Win32` puts `$(IncludePath)` ahead of the vendored directory. It was written
as `dshow.h` to preserve exactly that, keeping the edit a pure casing fix. Writing `DShow.h` would have
switched the translation unit to the 2002 vendored header — a behavioural change, and a decision for
whoever owns the DirectShow question upstream.

All ten were applied to the submodule working tree, and the tree **rebuilds clean**: 109 translation
units, LTCG, 0 errors, exit 0, byte-identical 1,666,560-byte `TMProject.exe`. A rescan reports zero
remaining mismatches. `TMProject.rc` was patched byte-safely and is still UTF-16 LE with a BOM and CRLF
line endings — a `.rc` silently rewritten to UTF-8 breaks `rc.exe`.

Method note worth keeping: **§10.6 was wrong because it was read rather than executed.** The same
15-line scan that produced this table would have produced it the first time.
