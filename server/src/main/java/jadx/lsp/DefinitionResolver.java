package jadx.lsp;

import jadx.api.ICodeInfo;
import jadx.api.JavaClass;
import jadx.api.JavaNode;
import jadx.api.JadxDecompiler;
import jadx.api.metadata.ICodeAnnotation;
import jadx.api.metadata.ICodeNodeRef;
import jadx.api.metadata.annotations.NodeDeclareRef;

import org.eclipse.lsp4j.Location;
import org.eclipse.lsp4j.Position;
import org.eclipse.lsp4j.Range;

import java.util.Optional;

/**
 * Resolves an LSP go-to-definition request against a loaded JadxDecompiler.
 *
 * Extracted from JadxLanguageServer so the logic can be unit-tested without
 * a live LSP connection or a real APK/DEX file.
 */
class DefinitionResolver {

    /**
     * Resolve a definition jump for the symbol at {@code cursorPos} inside the
     * class identified by {@code fqn}.
     *
     * <p>Calling {@link JavaClass#getCodeInfo()} on the target class is what
     * triggers on-demand decompilation in jadx.  We do this <em>before</em>
     * reading {@link JavaNode#getDefPos()} because getDefPos() returns 0 until
     * decompilation has run for that class.
     *
     * @return the target {@link Location}, or empty if resolution fails for any
     *         reason (class not found, cursor not on a symbol, etc.).
     */
    static Optional<Location> resolve(JadxDecompiler jadx, String fqn, Position cursorPos) {
        if (jadx == null || fqn == null) return Optional.empty();

        JavaClass cls = findClass(jadx, fqn);
        if (cls == null) return Optional.empty();

        ICodeInfo codeInfo = cls.getCodeInfo();
        int offset = PositionConverter.toOffset(codeInfo.getCodeStr(), cursorPos);

        ICodeNodeRef ref = toNodeRef(codeInfo.getCodeMetadata().getAt(offset));
        if (ref == null) return Optional.empty();

        JavaNode target = jadx.getJavaNodeByRef(ref);
        if (target == null) return Optional.empty();

        // Force decompilation of the target class BEFORE calling getDefPos().
        // getDefPos() returns 0 until the class has been decompiled; calling
        // getCodeInfo() is what triggers that decompilation on demand.
        JavaClass targetCls    = target.getTopParentClass();
        ICodeInfo targetCdInfo = targetCls.getCodeInfo();

        int defPos = target.getDefPos();
        if (defPos <= 0) return Optional.empty();

        String   targetCode = targetCdInfo.getCodeStr();
        Position pos        = PositionConverter.toPosition(targetCode, defPos);
        return Optional.of(new Location(
                "jadx://" + targetCls.getFullName(),
                new Range(pos, pos)));
    }

    /**
     * Look up a class by FQN, trying the original name first then the alias.
     */
    static JavaClass findClass(JadxDecompiler jadx, String fqn) {
        JavaClass cls = jadx.searchJavaClassByOrigFullName(fqn);
        if (cls == null) cls = jadx.searchJavaClassByAliasFullName(fqn);
        return cls;
    }

    /**
     * Normalise a code annotation to a navigable {@link ICodeNodeRef}.
     *
     * At a reference site the annotation IS the node ref directly.
     * At a declaration site it is wrapped in a {@link NodeDeclareRef}; we
     * unwrap it so both sites resolve to the same target.
     */
    static ICodeNodeRef toNodeRef(ICodeAnnotation ann) {
        if (ann == null) return null;
        if (ann instanceof NodeDeclareRef decl) return decl.getNode();
        if (ann instanceof ICodeNodeRef ref)   return ref;
        return null;
    }
}
