package jadx.lsp;

import com.google.gson.JsonElement;
import com.google.gson.JsonObject;

import jadx.api.ICodeInfo;
import jadx.api.JavaClass;
import jadx.api.JavaField;
import jadx.api.JavaMethod;
import jadx.api.JavaNode;
import jadx.api.JadxArgs;
import jadx.api.JadxDecompiler;
import jadx.api.metadata.ICodeAnnotation;
import jadx.api.metadata.ICodeNodeRef;
import jadx.api.metadata.annotations.NodeDeclareRef;
import jadx.core.dex.info.AccessInfo;
import jadx.core.dex.instructions.args.ArgType;

import org.eclipse.lsp4j.DefinitionParams;
import org.eclipse.lsp4j.DidChangeConfigurationParams;
import org.eclipse.lsp4j.DidChangeTextDocumentParams;
import org.eclipse.lsp4j.DidChangeWatchedFilesParams;
import org.eclipse.lsp4j.DidCloseTextDocumentParams;
import org.eclipse.lsp4j.DidOpenTextDocumentParams;
import org.eclipse.lsp4j.DidSaveTextDocumentParams;
import org.eclipse.lsp4j.Hover;
import org.eclipse.lsp4j.HoverParams;
import org.eclipse.lsp4j.InitializeParams;
import org.eclipse.lsp4j.InitializeResult;
import org.eclipse.lsp4j.InitializedParams;
import org.eclipse.lsp4j.Location;
import org.eclipse.lsp4j.LocationLink;
import org.eclipse.lsp4j.MarkupContent;
import org.eclipse.lsp4j.MarkupKind;
import org.eclipse.lsp4j.Position;
import org.eclipse.lsp4j.Range;
import org.eclipse.lsp4j.ServerCapabilities;
import org.eclipse.lsp4j.ServerInfo;
import org.eclipse.lsp4j.TextDocumentSyncKind;
import org.eclipse.lsp4j.jsonrpc.messages.Either;
import org.eclipse.lsp4j.services.LanguageClient;
import org.eclipse.lsp4j.services.LanguageClientAware;
import org.eclipse.lsp4j.services.LanguageServer;
import org.eclipse.lsp4j.services.TextDocumentService;
import org.eclipse.lsp4j.services.WorkspaceService;

import java.io.File;
import java.util.Collections;
import java.util.List;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

public class JadxLanguageServer
        implements LanguageServer, LanguageClientAware, TextDocumentService, JadxExtensions {

    private LanguageClient client;
    private JadxDecompiler jadx;

    /**
     * Completes once jadx has finished loading (or has been skipped because no
     * file was provided).  All requests that need jadx chain off this future so
     * they don't race with initialization.
     */
    private final CompletableFuture<Void> jadxReady = new CompletableFuture<>();

    private final ExecutorService executor = Executors.newCachedThreadPool();

    // ─── LanguageServer ───────────────────────────────────────────────────────

    @Override
    public CompletableFuture<InitializeResult> initialize(InitializeParams params) {
        // Start loading jadx in the background; respond to initialize immediately
        // so the client isn't blocked waiting for potentially slow decompilation.
        executor.submit(() -> {
            try {
                String jadxFile = extractJadxFile(params.getInitializationOptions());
                if (jadxFile != null) {
                    JadxArgs args = new JadxArgs();
                    args.setInputFile(new File(jadxFile));
                    jadx = new JadxDecompiler(args);
                    jadx.load();
                }
            } catch (Exception e) {
                stderr("Failed to load jadx: " + e.getMessage());
            } finally {
                jadxReady.complete(null);
            }
        });

        ServerCapabilities caps = new ServerCapabilities();
        caps.setTextDocumentSync(TextDocumentSyncKind.Full);
        caps.setHoverProvider(true);
        caps.setDefinitionProvider(true);
        // Tell the client to send character offsets in UTF-8 units.
        // jadx's decompiled output is ASCII-safe, so this mainly avoids confusion.
        caps.setPositionEncoding("utf-8");

        InitializeResult result = new InitializeResult(caps);
        result.setServerInfo(new ServerInfo("jadx-lsp", "0.1.0"));
        return CompletableFuture.completedFuture(result);
    }

    @Override
    public void initialized(InitializedParams params) {}

    @Override
    public CompletableFuture<Object> shutdown() {
        executor.shutdown();
        if (jadx != null) {
            jadx.close();
        }
        return CompletableFuture.completedFuture(null);
    }

    @Override
    public void exit() {
        System.exit(0);
    }

    @Override
    public TextDocumentService getTextDocumentService() { return this; }

    @Override
    public WorkspaceService getWorkspaceService() { return noOpWorkspaceService; }

    @Override
    public void connect(LanguageClient client) { this.client = client; }

    // ─── JadxExtensions ──────────────────────────────────────────────────────

    @Override
    public CompletableFuture<ClassSourceResult> classSource(ClassSourceParams params) {
        return jadxReady.thenApplyAsync(__ -> {
            if (jadx == null) return new ClassSourceResult(null);
            JavaClass cls = findClass(params.getFqn());
            if (cls == null) return new ClassSourceResult(null);
            return new ClassSourceResult(cls.getCode());
        }, executor);
    }

    // ─── TextDocumentService ─────────────────────────────────────────────────

    @Override
    public CompletableFuture<Either<List<? extends Location>, List<? extends LocationLink>>>
            definition(DefinitionParams params) {

        return jadxReady.thenApplyAsync(__ -> {
            List<Location> empty = Collections.emptyList();

            if (jadx == null) return left(empty);

            String fqn = fqnFromUri(params.getTextDocument().getUri());
            if (fqn == null) return left(empty);

            JavaClass cls = findClass(fqn);
            if (cls == null) return left(empty);

            ICodeInfo codeInfo = cls.getCodeInfo();
            int offset = PositionConverter.toOffset(codeInfo.getCodeStr(), params.getPosition());

            ICodeNodeRef ref = toNodeRef(codeInfo.getCodeMetadata().getAt(offset));
            if (ref == null) return left(empty);

            JavaNode target = jadx.getJavaNodeByRef(ref);
            if (target == null) return left(empty);

            int defPos = target.getDefPos();
            if (defPos <= 0) return left(empty);

            JavaClass targetCls  = target.getTopParentClass();
            String    targetCode = targetCls.getCodeInfo().getCodeStr();
            Position  pos        = PositionConverter.toPosition(targetCode, defPos);
            Location  loc        = new Location(
                    "jadx://" + targetCls.getFullName(),
                    new Range(pos, pos));
            return left(Collections.singletonList(loc));
        }, executor);
    }

    @Override
    public CompletableFuture<Hover> hover(HoverParams params) {
        return jadxReady.thenApplyAsync(__ -> {
            if (jadx == null) return null;

            String fqn = fqnFromUri(params.getTextDocument().getUri());
            if (fqn == null) return null;

            JavaClass cls = findClass(fqn);
            if (cls == null) return null;

            ICodeInfo codeInfo = cls.getCodeInfo();
            int offset = PositionConverter.toOffset(codeInfo.getCodeStr(), params.getPosition());

            ICodeNodeRef ref = toNodeRef(codeInfo.getCodeMetadata().getAt(offset));
            if (ref == null) return null;

            JavaNode node = jadx.getJavaNodeByRef(ref);
            if (node == null) return null;

            String markdown = buildHoverMarkdown(node);
            if (markdown == null) return null;

            return new Hover(new MarkupContent(MarkupKind.MARKDOWN, markdown));
        }, executor);
    }

    // Notifications we don't act on.
    @Override public void didOpen(DidOpenTextDocumentParams p)    {}
    @Override public void didChange(DidChangeTextDocumentParams p) {}
    @Override public void didClose(DidCloseTextDocumentParams p)   {}
    @Override public void didSave(DidSaveTextDocumentParams p)     {}

    // ─── Helpers ─────────────────────────────────────────────────────────────

    private JavaClass findClass(String fqn) {
        if (fqn == null || jadx == null) return null;
        JavaClass cls = jadx.searchJavaClassByOrigFullName(fqn);
        if (cls == null) cls = jadx.searchJavaClassByAliasFullName(fqn);
        return cls;
    }

    /** "jadx://com.example.Foo" -> "com.example.Foo", anything else -> null. */
    private static String fqnFromUri(String uri) {
        if (uri == null || !uri.startsWith("jadx://")) return null;
        return uri.substring("jadx://".length());
    }

    /**
     * Normalise an annotation to a navigable ICodeNodeRef.
     *
     * At a reference site the annotation IS the node (ClassNode/MethodNode/FieldNode
     * all implement ICodeNodeRef).  At a declaration site the annotation is a
     * NodeDeclareRef wrapper; we unwrap it so hover still shows info.
     */
    private static ICodeNodeRef toNodeRef(ICodeAnnotation ann) {
        if (ann == null) return null;
        if (ann instanceof NodeDeclareRef decl) return decl.getNode();
        if (ann instanceof ICodeNodeRef ref)   return ref;
        return null;
    }

    private static String buildHoverMarkdown(JavaNode node) {
        if (node instanceof JavaClass cls) {
            AccessInfo access = cls.getAccessInfo();
            String kind = access.isInterface() ? "interface"
                        : access.isEnum()      ? "enum"
                        :                        "class";
            return "```java\n" + kind + " " + cls.getFullName() + "\n```";
        }
        if (node instanceof JavaMethod mth) {
            StringBuilder sb = new StringBuilder("```java\n");
            sb.append(mth.getReturnType()).append(' ').append(mth.getName()).append('(');
            List<ArgType> argTypes = mth.getArguments();
            for (int i = 0; i < argTypes.size(); i++) {
                if (i > 0) sb.append(", ");
                sb.append(argTypes.get(i));
            }
            sb.append(")\n```");
            return sb.toString();
        }
        if (node instanceof JavaField fld) {
            return "```java\n" + fld.getType() + " " + fld.getFullName() + "\n```";
        }
        return null;
    }

    private static String extractJadxFile(Object initializationOptions) {
        if (initializationOptions instanceof JsonObject json) {
            JsonElement el = json.get("jadxFile");
            if (el != null && !el.isJsonNull()) return el.getAsString();
        }
        return null;
    }

    /** Type-inference helper to avoid verbose casts on Either.forLeft(). */
    private static Either<List<? extends Location>, List<? extends LocationLink>>
            left(List<Location> locs) {
        return Either.forLeft(locs);
    }

    private static void stderr(String msg) {
        System.err.println("[jadx-lsp] " + msg);
    }

    // ─── No-op WorkspaceService ───────────────────────────────────────────────

    private static final WorkspaceService noOpWorkspaceService = new WorkspaceService() {
        @Override public void didChangeConfiguration(DidChangeConfigurationParams p) {}
        @Override public void didChangeWatchedFiles(DidChangeWatchedFilesParams p)   {}
    };
}
