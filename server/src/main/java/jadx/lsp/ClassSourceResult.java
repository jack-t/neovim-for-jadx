package jadx.lsp;

/** Result of the jadx/classSource request. */
public class ClassSourceResult {
    private final String source;

    public ClassSourceResult(String source) { this.source = source; }
    public String getSource()               { return source; }
}
