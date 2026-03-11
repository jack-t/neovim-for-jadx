package jadx.lsp;

import org.eclipse.lsp4j.Position;

/**
 * Converts between LSP (line, character) positions and jadx's raw character
 * offsets into a decompiled source string.
 *
 * jadx's ICodeMetadata.getAt(int) takes a character offset counting from the
 * start of the string returned by ICodeInfo.getCodeStr().  LSP positions are
 * (0-based line, 0-based UTF-16 character).  Because jadx's decompiled output
 * is ASCII-only in practice (non-ASCII identifiers are renamed), UTF-16 and
 * UTF-8 code-unit counts are the same for all positions we will encounter.
 * If that assumption ever breaks, positionEncoding:"utf-8" in ServerCapabilities
 * tells the client to send UTF-8 offsets instead.
 */
public final class PositionConverter {

    private PositionConverter() {}

    /**
     * Convert an LSP position to a raw character offset.
     * Clamps gracefully if the position is past the end of the code string.
     */
    public static int toOffset(String code, Position pos) {
        int targetLine = pos.getLine();
        int targetChar = pos.getCharacter();

        int line = 0;
        for (int i = 0; i < code.length(); i++) {
            if (line == targetLine) {
                return Math.min(i + targetChar, code.length());
            }
            if (code.charAt(i) == '\n') {
                line++;
            }
        }
        return code.length();
    }

    /**
     * Convert a raw character offset back to an LSP position.
     * Clamps gracefully if the offset is past the end of the code string.
     */
    public static Position toPosition(String code, int offset) {
        int clampedOffset = Math.min(offset, code.length());
        int line      = 0;
        int lineStart = 0;

        for (int i = 0; i < clampedOffset; i++) {
            if (code.charAt(i) == '\n') {
                line++;
                lineStart = i + 1;
            }
        }
        return new Position(line, clampedOffset - lineStart);
    }
}
