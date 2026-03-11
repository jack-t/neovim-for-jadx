package jadx.lsp;

import org.eclipse.lsp4j.jsonrpc.services.JsonRequest;

import java.util.concurrent.CompletableFuture;

/**
 * Custom LSP requests specific to jadx that fall outside the standard LSP spec.
 * lsp4j discovers @JsonRequest methods via reflection on the server object, so
 * implementing this interface is all that is needed to route these requests.
 */
public interface JadxExtensions {

    @JsonRequest("jadx/classSource")
    CompletableFuture<ClassSourceResult> classSource(ClassSourceParams params);
}
