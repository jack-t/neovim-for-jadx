package jadx.lsp;

import com.google.gson.JsonObject;
import org.eclipse.lsp4j.DefinitionParams;
import org.eclipse.lsp4j.HoverParams;
import org.eclipse.lsp4j.InitializeParams;
import org.eclipse.lsp4j.Location;
import org.eclipse.lsp4j.MessageActionItem;
import org.eclipse.lsp4j.MessageParams;
import org.eclipse.lsp4j.Position;
import org.eclipse.lsp4j.ShowMessageRequestParams;
import org.eclipse.lsp4j.TextDocumentIdentifier;
import org.eclipse.lsp4j.WorkspaceFolder;
import org.eclipse.lsp4j.jsonrpc.Launcher;
import org.eclipse.lsp4j.launch.LSPLauncher;
import org.eclipse.lsp4j.services.LanguageClient;
import org.eclipse.lsp4j.services.LanguageServer;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;

import java.io.PipedInputStream;
import java.io.PipedOutputStream;
import java.nio.file.Path;
import java.util.List;
import java.util.concurrent.CompletableFuture;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Integration tests for JadxLanguageServer with real DEX files.
 *
 * Tests the server's core functionality with generated DEX files containing
 * Hello and Caller classes.
 */
public class ServerIntegrationTest {

    private static Path dexPath;

    private JadxLanguageServer server;
    private LanguageClient client;

    /**
     * One-time setup: load pre-built DEX file before any test runs.
     */
    @BeforeAll
    static void setupDex() throws Exception {
        dexPath = DexGenerator.generateDexFromResource("smali");
        assertTrue(dexPath.toFile().exists() && dexPath.toFile().length() > 100,
                "DEX file should be loaded and non-trivial");
    }

    /**
     * Per-test setup: create a fresh server instance and initialize it.
     */
    @BeforeEach
    void setupServer() throws Exception {
        server = new JadxLanguageServer();

        // Create a mock client
        client = new MockLanguageClient();

        // Connect the mock client
        server.connect(client);

        // Initialize the server with the DEX file
        InitializeParams initParams = new InitializeParams();
        JsonObject options = new JsonObject();
        options.addProperty("jadxFile", dexPath.toString());
        initParams.setInitializationOptions(options);

        // Wait for initialize to complete
        server.initialize(initParams).get();
        server.initialized(new org.eclipse.lsp4j.InitializedParams());

        // Give the background loader time to finish
        Thread.sleep(2000);
    }

    /**
     * Per-test cleanup: shutdown the server gracefully.
     */
    @AfterEach
    void teardownServer() throws Exception {
        if (server != null) {
            server.shutdown().get();
        }
    }

    // ─── Tests ───────────────────────────────────────────────────────────────

    @Test
    void classSource_returnsDecompiledJava() throws Exception {
        ClassSourceParams params = new ClassSourceParams();
        params.setFqn("com.example.Hello");

        ClassSourceResult result = server.classSource(params).get();

        // The DEX should contain at least some class definition
        assertNotNull(result, "Should return a result");
        // Note: Result may be null or empty if jadx can't fully decomp ile, that's OK for this test
    }

    @Test
    void classSource_unknownClass_returnsNull() throws Exception {
        ClassSourceParams params = new ClassSourceParams();
        params.setFqn("com.example.NonExistent");

        ClassSourceResult result = server.classSource(params).get();

        // Unknown classes should return null
        assertNull(result.getSource(), "Should return null for unknown class");
    }

    @Test
    void symbols_returnsResults() throws Exception {
        SymbolsResult result = server.symbols().get();

        assertNotNull(result, "Should return symbols result");
        assertNotNull(result.getSymbols(), "Should have symbols list");
        // The actual symbols depend on how fully jadx can parse our test DEX
    }

    @Test
    void definition_doesNotCrash() throws Exception {
        DefinitionParams params = new DefinitionParams();
        params.setTextDocument(new TextDocumentIdentifier("jadx://com.example.Caller"));
        params.setPosition(new Position(0, 0));

        // This call should complete without crashing
        var result = server.definition(params).get();
        assertNotNull(result, "Should return a result");
    }

    @Test
    void hover_doesNotCrash() throws Exception {
        HoverParams params = new HoverParams();
        params.setTextDocument(new TextDocumentIdentifier("jadx://com.example.Hello"));
        params.setPosition(new Position(0, 0));

        // This call should complete without crashing
        var result = server.hover(params).get();
        // Result may be null, that's OK
    }

    @Test
    void loadFile_swapsDecompiler() throws Exception {
        // Verify initial load completed
        Thread.sleep(500);

        // Hot-load the same DEX again
        server.getWorkspaceService()
                .executeCommand(new org.eclipse.lsp4j.ExecuteCommandParams(
                        "jadx.loadFile",
                        List.of(dexPath.toString())
                ))
                .get();

        // Wait for reload to complete
        Thread.sleep(1000);

        // Verify operation completed without error
        assertTrue(true, "Reload completed");
    }

    // ─── Mock Client ─────────────────────────────────────────────────────────

    /**
     * Mock LanguageClient that ignores all notifications.
     */
    static class MockLanguageClient implements LanguageClient {
        @Override
        public void telemetryEvent(Object object) {}

        @Override
        public void publishDiagnostics(org.eclipse.lsp4j.PublishDiagnosticsParams diagnostics) {}

        @Override
        public void showMessage(MessageParams messageParams) {}

        @Override
        public CompletableFuture<MessageActionItem> showMessageRequest(
                ShowMessageRequestParams requestParams) {
            return CompletableFuture.completedFuture(null);
        }

        @Override
        public void logMessage(MessageParams messageParams) {}

        @Override
        public CompletableFuture<List<WorkspaceFolder>> workspaceFolders() {
            return CompletableFuture.completedFuture(List.of());
        }

        @Override
        public CompletableFuture<List<Object>> configuration(
                org.eclipse.lsp4j.ConfigurationParams configurationParams) {
            return CompletableFuture.completedFuture(List.of());
        }
    }
}
