package jadx.lsp;

/** Parameters for the jadx/classSource request. */
public class ClassSourceParams {
    private String fqn;

    public String getFqn()           { return fqn; }
    public void   setFqn(String fqn) { this.fqn = fqn; }
}
