# Development Guide

## Running the End-to-End Tests

The E2E tests exercise the full plugin workflow: starting the jadx-lsp server,
opening DEX classes, navigating definitions, and checking buffer contents.

### Prerequisites

- **Neovim** (any recent version)
- **Java 17+** (required to build and run the server)
- **Network access to Maven Central and Google Maven** (`dl.google.com`) — the
  build downloads `jadx-core`, `jadx-dex-input`, and their transitive dependency
  `com.android.tools.smali:smali-baksmali` from those repositories

### Running

```bash
bash run_e2e_tests.sh
```

The script:
1. Builds `server/build/libs/jadx-lsp.jar` via `./gradlew shadowJar` if it does
   not already exist
2. Extracts `test.dex` (a minimal DEX with `Hello` and `Caller` classes) from
   the JAR
3. Launches Neovim in headless mode with an isolated config that loads the plugin
   and runs the test suite
4. Prints pass/fail results and exits non-zero if any test fails

### Test Cases

| Test | What it checks |
|------|----------------|
| Plugin Loaded | `require("jadx")` succeeds |
| JADX Commands Exist | `JadxOpen`, `JadxLoad`, `JadxStatus` are registered |
| Open Class from URI | `edit jadx://com.example.Hello` produces a non-empty buffer |
| JadxOpen Command | `:JadxOpen com.example.Caller` produces a buffer |
| Status Buffer | `:JadxStatus` creates a `jadx://status` buffer |
| Load File Command | `:JadxLoad <path>` does not crash |

### Building the Server Separately

```bash
cd server
./gradlew shadowJar
# Output: build/libs/jadx-lsp.jar
```

To also run the unit and integration tests:

```bash
cd server
./gradlew test integrationTest
```
