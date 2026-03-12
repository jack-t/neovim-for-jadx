package jadx.lsp;

import jadx.api.ICodeInfo;
import jadx.api.JavaClass;
import jadx.api.JavaNode;
import jadx.api.JadxDecompiler;
import jadx.api.metadata.ICodeAnnotation;
import jadx.api.metadata.ICodeMetadata;
import jadx.api.metadata.ICodeNodeRef;
import jadx.api.metadata.annotations.NodeDeclareRef;

import org.eclipse.lsp4j.Location;
import org.eclipse.lsp4j.Position;
import org.junit.jupiter.api.Test;

import java.util.Optional;
import java.util.concurrent.atomic.AtomicBoolean;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.anyInt;
import static org.mockito.Mockito.*;

/**
 * Unit tests for {@link DefinitionResolver}.
 *
 * All jadx objects are mocked; no real APK/DEX is needed.
 */
class DefinitionResolverTest {

    // ─── Null / missing inputs ────────────────────────────────────────────────

    @Test
    void resolve_returnsEmptyForNullJadx() {
        assertTrue(DefinitionResolver.resolve(null, "com.example.Foo", pos(0, 0)).isEmpty());
    }

    @Test
    void resolve_returnsEmptyForNullFqn() {
        JadxDecompiler jadx = mock(JadxDecompiler.class);
        assertTrue(DefinitionResolver.resolve(jadx, null, pos(0, 0)).isEmpty());
    }

    @Test
    void resolve_returnsEmptyWhenSourceClassNotFound() {
        JadxDecompiler jadx = mock(JadxDecompiler.class);
        when(jadx.searchJavaClassByOrigFullName("com.example.Missing")).thenReturn(null);
        when(jadx.searchJavaClassByAliasFullName("com.example.Missing")).thenReturn(null);

        assertTrue(DefinitionResolver.resolve(jadx, "com.example.Missing", pos(0, 0)).isEmpty());
    }

    @Test
    void resolve_returnsEmptyWhenNoAnnotationAtCursor() {
        JadxDecompiler jadx   = mock(JadxDecompiler.class);
        JavaClass      cls    = mock(JavaClass.class);
        ICodeInfo      info   = mock(ICodeInfo.class);
        ICodeMetadata  meta   = mock(ICodeMetadata.class);

        when(jadx.searchJavaClassByOrigFullName("com.example.Foo")).thenReturn(cls);
        when(cls.getCodeInfo()).thenReturn(info);
        when(info.getCodeStr()).thenReturn("class Foo {}");
        when(info.getCodeMetadata()).thenReturn(meta);
        when(meta.getAt(anyInt())).thenReturn(null); // no symbol at cursor

        assertTrue(DefinitionResolver.resolve(jadx, "com.example.Foo", pos(0, 6)).isEmpty());
    }

    @Test
    void resolve_returnsEmptyWhenTargetNodeIsNull() {
        // jadx can't map the ref to a JavaNode (e.g. external library symbol)
        JadxDecompiler jadx   = mock(JadxDecompiler.class);
        JavaClass      cls    = mock(JavaClass.class);
        ICodeInfo      info   = mock(ICodeInfo.class);
        ICodeMetadata  meta   = mock(ICodeMetadata.class);
        ICodeNodeRef   ref    = mockDirectRef();

        when(jadx.searchJavaClassByOrigFullName("com.example.Foo")).thenReturn(cls);
        when(cls.getCodeInfo()).thenReturn(info);
        when(info.getCodeStr()).thenReturn("class Foo {}");
        when(info.getCodeMetadata()).thenReturn(meta);
        when(meta.getAt(anyInt())).thenReturn((ICodeAnnotation) ref);
        when(jadx.getJavaNodeByRef(ref)).thenReturn(null);

        assertTrue(DefinitionResolver.resolve(jadx, "com.example.Foo", pos(0, 0)).isEmpty());
    }

    // ─── Normal navigation (target already decompiled) ────────────────────────

    @Test
    void resolve_navigatesWhenTargetAlreadyDecompiled() {
        // "Already decompiled" means getDefPos() returns a valid offset immediately
        // without needing getCodeInfo() to trigger anything first.
        String targetSrc = "class Bar {\nvoid baz() {}\n}";
        // "void" starts at offset 12 (= after "class Bar {\n" which is 12 chars)

        JadxDecompiler jadx       = mock(JadxDecompiler.class);
        JavaClass      sourceCls  = mock(JavaClass.class);
        ICodeInfo      sourceInfo = mock(ICodeInfo.class);
        ICodeMetadata  sourceMeta = mock(ICodeMetadata.class);
        ICodeNodeRef   ref        = mockDirectRef();
        JavaNode       target     = mock(JavaNode.class);
        JavaClass      targetCls  = mock(JavaClass.class);
        ICodeInfo      targetInfo = mock(ICodeInfo.class);

        when(jadx.searchJavaClassByOrigFullName("com.example.Foo")).thenReturn(sourceCls);
        when(sourceCls.getCodeInfo()).thenReturn(sourceInfo);
        when(sourceInfo.getCodeStr()).thenReturn("// Foo source");
        when(sourceInfo.getCodeMetadata()).thenReturn(sourceMeta);
        when(sourceMeta.getAt(anyInt())).thenReturn((ICodeAnnotation) ref);
        when(jadx.getJavaNodeByRef(ref)).thenReturn(target);
        when(target.getTopParentClass()).thenReturn(targetCls);
        when(targetCls.getCodeInfo()).thenReturn(targetInfo);
        when(targetInfo.getCodeStr()).thenReturn(targetSrc);
        when(target.getDefPos()).thenReturn(12); // offset of 'v' in "void"
        when(targetCls.getFullName()).thenReturn("com.example.Bar");

        Optional<Location> result = DefinitionResolver.resolve(jadx, "com.example.Foo", pos(0, 3));

        assertTrue(result.isPresent());
        assertEquals("jadx://com.example.Bar", result.get().getUri());
        // offset 12 in "class Bar {\nvoid baz() {}\n}" is line 1, char 0
        assertEquals(1, result.get().getRange().getStart().getLine());
        assertEquals(0, result.get().getRange().getStart().getCharacter());
    }

    // ─── THE KEY TEST: ordering fix for undecompiled target ──────────────────

    /**
     * Exercises the bug that was present before the fix.
     *
     * <p>In the real jadx API, {@link JavaNode#getDefPos()} returns 0 until the
     * containing class has been decompiled.  Decompilation is triggered by
     * {@link JavaClass#getCodeInfo()}.  The bug was that getDefPos() was called
     * <em>before</em> getCodeInfo(), so navigating to a symbol in a class that
     * had not yet been opened always silently returned empty.
     *
     * <p>We simulate this with a stateful mock: {@code getDefPos()} returns 0
     * unless the decompilation flag has been set, and calling
     * {@code getCodeInfo()} on the target class is what sets that flag.
     * With the correct ordering (getCodeInfo first, getDefPos second) the test
     * passes.  Reverting the ordering makes it fail.
     */
    @Test
    void resolve_navigatesWhenTargetNotYetDecompiled() {
        String targetSrc = "class Bar {\nvoid baz() {}\n}";

        // Simulates jadx's lazy decompilation: getCodeInfo() triggers it.
        AtomicBoolean targetDecompiled = new AtomicBoolean(false);

        JadxDecompiler jadx       = mock(JadxDecompiler.class);
        JavaClass      sourceCls  = mock(JavaClass.class);
        ICodeInfo      sourceInfo = mock(ICodeInfo.class);
        ICodeMetadata  sourceMeta = mock(ICodeMetadata.class);
        ICodeNodeRef   ref        = mockDirectRef();
        JavaNode       target     = mock(JavaNode.class);
        JavaClass      targetCls  = mock(JavaClass.class);
        ICodeInfo      targetInfo = mock(ICodeInfo.class);

        when(jadx.searchJavaClassByOrigFullName("com.example.Foo")).thenReturn(sourceCls);
        when(sourceCls.getCodeInfo()).thenReturn(sourceInfo);
        when(sourceInfo.getCodeStr()).thenReturn("// Foo source");
        when(sourceInfo.getCodeMetadata()).thenReturn(sourceMeta);
        when(sourceMeta.getAt(anyInt())).thenReturn((ICodeAnnotation) ref);
        when(jadx.getJavaNodeByRef(ref)).thenReturn(target);
        when(target.getTopParentClass()).thenReturn(targetCls);

        // Calling getCodeInfo() on the target class "decompiles" it.
        when(targetCls.getCodeInfo()).thenAnswer(inv -> {
            targetDecompiled.set(true);
            return targetInfo;
        });
        when(targetInfo.getCodeStr()).thenReturn(targetSrc);

        // getDefPos() returns 0 (invalid) before decompilation, 12 after.
        when(target.getDefPos()).thenAnswer(inv -> targetDecompiled.get() ? 12 : 0);
        when(targetCls.getFullName()).thenReturn("com.example.Bar");

        Optional<Location> result = DefinitionResolver.resolve(jadx, "com.example.Foo", pos(0, 3));

        assertTrue(result.isPresent(),
                "Should resolve even when the target class has not yet been decompiled");
        assertEquals("jadx://com.example.Bar", result.get().getUri());
        assertEquals(1, result.get().getRange().getStart().getLine());

        // Confirm getCodeInfo() was actually called (which is what triggered decompilation).
        verify(targetCls, atLeastOnce()).getCodeInfo();
    }

    @Test
    void resolve_returnsEmptyWhenDefPosIsZeroAfterDecompilation() {
        // Even after decompilation some nodes (synthetic constructors, bridge
        // methods, etc.) have no declaration position.  We must still return
        // empty for those rather than producing a bogus location.
        JadxDecompiler jadx       = mock(JadxDecompiler.class);
        JavaClass      sourceCls  = mock(JavaClass.class);
        ICodeInfo      sourceInfo = mock(ICodeInfo.class);
        ICodeMetadata  sourceMeta = mock(ICodeMetadata.class);
        ICodeNodeRef   ref        = mockDirectRef();
        JavaNode       target     = mock(JavaNode.class);
        JavaClass      targetCls  = mock(JavaClass.class);
        ICodeInfo      targetInfo = mock(ICodeInfo.class);

        when(jadx.searchJavaClassByOrigFullName("com.example.Foo")).thenReturn(sourceCls);
        when(sourceCls.getCodeInfo()).thenReturn(sourceInfo);
        when(sourceInfo.getCodeStr()).thenReturn("// Foo source");
        when(sourceInfo.getCodeMetadata()).thenReturn(sourceMeta);
        when(sourceMeta.getAt(anyInt())).thenReturn((ICodeAnnotation) ref);
        when(jadx.getJavaNodeByRef(ref)).thenReturn(target);
        when(target.getTopParentClass()).thenReturn(targetCls);
        when(targetCls.getCodeInfo()).thenReturn(targetInfo);
        when(targetInfo.getCodeStr()).thenReturn("class Bar {}");
        when(target.getDefPos()).thenReturn(0); // no declaration position

        assertTrue(DefinitionResolver.resolve(jadx, "com.example.Foo", pos(0, 0)).isEmpty());
    }

    // ─── toNodeRef ────────────────────────────────────────────────────────────

    @Test
    void toNodeRef_returnsNullForNull() {
        assertNull(DefinitionResolver.toNodeRef(null));
    }

    @Test
    void toNodeRef_returnsNullForUnknownAnnotationType() {
        // An ICodeAnnotation that is neither a NodeDeclareRef nor an ICodeNodeRef.
        ICodeAnnotation unknown = mock(ICodeAnnotation.class);
        assertNull(DefinitionResolver.toNodeRef(unknown));
    }

    @Test
    void toNodeRef_unwrapsNodeDeclareRef() {
        ICodeNodeRef   inner   = mock(ICodeNodeRef.class);
        NodeDeclareRef wrapper = mock(NodeDeclareRef.class);
        when(wrapper.getNode()).thenReturn(inner);

        assertSame(inner, DefinitionResolver.toNodeRef(wrapper));
    }

    @Test
    void toNodeRef_returnsDirectNodeRef() {
        // An annotation that is already an ICodeNodeRef (reference site, not declaration site).
        ICodeNodeRef ref = mockDirectRef();
        assertSame(ref, DefinitionResolver.toNodeRef((ICodeAnnotation) ref));
    }

    // ─── findClass ───────────────────────────────────────────────────────────

    @Test
    void findClass_findsViaOriginalName() {
        JadxDecompiler jadx = mock(JadxDecompiler.class);
        JavaClass      cls  = mock(JavaClass.class);
        when(jadx.searchJavaClassByOrigFullName("com.example.Foo")).thenReturn(cls);

        assertSame(cls, DefinitionResolver.findClass(jadx, "com.example.Foo"));
        verify(jadx, never()).searchJavaClassByAliasFullName(any());
    }

    @Test
    void findClass_fallsBackToAliasName() {
        JadxDecompiler jadx = mock(JadxDecompiler.class);
        JavaClass      cls  = mock(JavaClass.class);
        when(jadx.searchJavaClassByOrigFullName("com.example.a")).thenReturn(null);
        when(jadx.searchJavaClassByAliasFullName("com.example.a")).thenReturn(cls);

        assertSame(cls, DefinitionResolver.findClass(jadx, "com.example.a"));
    }

    @Test
    void findClass_returnsNullWhenNotFoundByEitherName() {
        JadxDecompiler jadx = mock(JadxDecompiler.class);
        when(jadx.searchJavaClassByOrigFullName(any())).thenReturn(null);
        when(jadx.searchJavaClassByAliasFullName(any())).thenReturn(null);

        assertNull(DefinitionResolver.findClass(jadx, "com.example.Unknown"));
    }

    // ─── Helpers ─────────────────────────────────────────────────────────────

    private static Position pos(int line, int character) {
        return new Position(line, character);
    }

    /**
     * Creates a mock that implements both {@link ICodeNodeRef} and
     * {@link ICodeAnnotation}, matching the layout of a reference-site
     * annotation in jadx (the node itself IS the annotation).
     */
    private static ICodeNodeRef mockDirectRef() {
        return mock(ICodeNodeRef.class,
                withSettings().extraInterfaces(ICodeAnnotation.class));
    }
}
