# jadx.nvim — Design Notes

## What this is

A Neovim plugin + LSP server that lets you navigate decompiled Android bytecode
(APK/DEX/JAR) as if it were source code.  The LSP server wraps jadx-core's Java
API; the plugin handles the custom `jadx://` URI scheme Neovim doesn't know about.

## Repository layout

```
lua/jadx/init.lua     Neovim plugin (single file)
stub/server.py        Python stub server — no jadx dependency, used for
                      exercising the plugin end-to-end before the Java
                      server is ready
server/               Gradle project → jadx-lsp.jar
  build.gradle        Shadow (fat) jar; mergeServiceFiles() is required
                      because jadx uses ServiceLoader for input plugins
  src/main/java/jadx/lsp/
    Main.java
    JadxLanguageServer.java
    JadxExtensions.java        @JsonRequest("jadx/classSource")
    ClassSourceParams/Result   Gson POJOs
    PositionConverter.java
```

## Protocol extension: jadx/classSource

Standard LSP has no way to serve synthetic source.  We add one custom request:

```
C→S  jadx/classSource  { fqn: "com.example.Foo" }
S→C                    { source: "<decompiled java>" }
```

The plugin's `BufReadCmd` autocmd fires on `jadx://*`, extracts the FQN, sends
this request, and fills the buffer when the response arrives.

## jadx-core API surface used

- `JadxDecompiler(JadxArgs)` / `.load()` / `.close()`
- `searchJavaClassByOrigFullName(fqn)` + `searchJavaClassByAliasFullName(fqn)`
  (alias fallback needed for deobfuscated names)
- `JavaClass.getCodeInfo()` → `ICodeInfo` → `getCodeStr()` + `getCodeMetadata()`
- `ICodeMetadata.getAt(charOffset)` → `ICodeAnnotation`
  — at a **reference** site the annotation IS the node (`ClassNode`/`MethodNode`/
    `FieldNode` implement `ICodeNodeRef`); at a **declaration** site it is a
    `NodeDeclareRef` wrapper — `toNodeRef()` in the server normalises both
- `JadxDecompiler.getJavaNodeByRef(ICodeNodeRef)` → `JavaNode`
- `JavaNode.getTopParentClass()` + `.getDefPos()` → navigation target
  (defPos is a char offset in the top-level class's code string)

## Position model

jadx uses raw **character offsets** into the string from `getCodeStr()`.
LSP uses **(line, character)** pairs.  `PositionConverter` converts between them
with a single linear scan.  The server advertises `positionEncoding: "utf-8"` so
the client doesn't send UTF-16 offsets; in practice jadx output is ASCII-safe.

## Async initialisation

`initialize()` returns immediately with capabilities; `jadx.load()` runs on a
background thread.  A `CompletableFuture<Void> jadxReady` gates every request
that touches jadx via `thenApplyAsync`, so no request races with loading.

## Definition navigation race (plugin-side)

`textDocument/definition` returns `{ uri: "jadx://...", range: { start: ... } }`.
Neovim would normally open the buffer and set the cursor in the same call, but the
buffer fill is async (another round-trip to the server for `jadx/classSource`).

Fix: the plugin overrides `vim.lsp.handlers["textDocument/definition"]`.
- If `vim.b[bufnr].jadx_loaded` is set the buffer is already filled → jump now.
- Otherwise stash the position in `pending_jumps[uri]`; `read_jadx_buf` applies
  it at the end of the `vim.schedule` block that calls `fill_buffer`.

## Known gaps / next steps

- `jadx/classSource` returns `null` source when no file was provided at startup;
  a `workspace/executeCommand` to hot-load a file would be useful.
- Hover covers CLASS/METHOD/FIELD only; local variable types (VarNode, which is
  internal API) are not yet surfaced.
- `server/build.gradle` dependency versions (`jadx-core:1.5.4`,
  `org.eclipse.lsp4j:0.24.0`) should be verified against Maven Central before
  first build.
- APK input support may require additional jadx plugin JARs on the classpath
  beyond `jadx-core`; `mergeServiceFiles()` in the shadow task ensures the
  ServiceLoader entries survive JAR merging.
