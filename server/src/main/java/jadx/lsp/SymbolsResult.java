package jadx.lsp;

import java.util.List;

/** Result of the jadx/symbols request — lists all known class, method, and field names. */
public class SymbolsResult {
    private final List<SymbolEntry> symbols;

    public SymbolsResult(List<SymbolEntry> symbols) { this.symbols = symbols; }
    public List<SymbolEntry> getSymbols()            { return symbols; }

    public static class SymbolEntry {
        private final String name;
        private final String kind;      // "class", "method", or "field"
        private final String parent;    // containing class FQN

        public SymbolEntry(String name, String kind, String parent) {
            this.name   = name;
            this.kind   = kind;
            this.parent = parent;
        }

        public String getName()   { return name; }
        public String getKind()   { return kind; }
        public String getParent() { return parent; }
    }
}
