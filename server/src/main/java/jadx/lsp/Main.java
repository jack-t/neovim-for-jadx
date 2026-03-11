package jadx.lsp;

import org.eclipse.lsp4j.launch.LSPLauncher;
import org.eclipse.lsp4j.services.LanguageClient;

import java.util.logging.Level;
import java.util.logging.Logger;

public class Main {
    public static void main(String[] args) throws Exception {
        // lsp4j uses java.util.logging internally; silence it so nothing leaks to stderr.
        Logger.getLogger("").setLevel(Level.WARNING);

        JadxLanguageServer server = new JadxLanguageServer();
        var launcher = LSPLauncher.createServerLauncher(server, System.in, System.out);
        server.connect(launcher.getRemoteProxy());
        // Blocks until the client disconnects.
        launcher.startListening().get();
    }
}
