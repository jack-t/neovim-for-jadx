package jadx.lsp;

import org.eclipse.lsp4j.Position;
import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

class PositionConverterTest {

    // ─── toOffset ────────────────────────────────────────────────────────────

    @Test
    void toOffset_firstCharOfFirstLine() {
        assertEquals(0, PositionConverter.toOffset("hello", pos(0, 0)));
    }

    @Test
    void toOffset_midLine() {
        assertEquals(3, PositionConverter.toOffset("hello", pos(0, 3)));
    }

    @Test
    void toOffset_firstCharOfSecondLine() {
        // "abc\ndef" — line 1 starts at offset 4
        assertEquals(4, PositionConverter.toOffset("abc\ndef", pos(1, 0)));
    }

    @Test
    void toOffset_midSecondLine() {
        assertEquals(6, PositionConverter.toOffset("abc\ndef", pos(1, 2)));
    }

    @Test
    void toOffset_charPastEndOfLineClampsToCodeLength() {
        // Line 0 is "abc" (length 3). Asking for character 99 should not
        // land in line 1's content — it clamps to code.length().
        // "abc\ndef" has length 7.
        assertEquals(7, PositionConverter.toOffset("abc\ndef", pos(0, 99)));
    }

    @Test
    void toOffset_linePastEndClampsToCodeLength() {
        assertEquals(5, PositionConverter.toOffset("hello", pos(99, 0)));
    }

    @Test
    void toOffset_emptyString() {
        assertEquals(0, PositionConverter.toOffset("", pos(0, 0)));
    }

    @Test
    void toOffset_singleNewline() {
        // "\n" — line 1 starts at offset 1, which equals code.length()
        assertEquals(1, PositionConverter.toOffset("\n", pos(1, 0)));
    }

    @Test
    void toOffset_trailingNewline() {
        // "abc\n" — line 1 exists but is empty; offset should be 4 (= length)
        assertEquals(4, PositionConverter.toOffset("abc\n", pos(1, 0)));
    }

    // ─── toPosition ──────────────────────────────────────────────────────────

    @Test
    void toPosition_offsetZero() {
        assertEquals(pos(0, 0), PositionConverter.toPosition("hello", 0));
    }

    @Test
    void toPosition_midLine() {
        assertEquals(pos(0, 3), PositionConverter.toPosition("hello", 3));
    }

    @Test
    void toPosition_endOfFirstLine() {
        // offset 3 = 'c' in "abc\ndef", still line 0
        assertEquals(pos(0, 3), PositionConverter.toPosition("abc\ndef", 3));
    }

    @Test
    void toPosition_firstCharOfSecondLine() {
        assertEquals(pos(1, 0), PositionConverter.toPosition("abc\ndef", 4));
    }

    @Test
    void toPosition_midSecondLine() {
        assertEquals(pos(1, 2), PositionConverter.toPosition("abc\ndef", 6));
    }

    @Test
    void toPosition_offsetPastEndClampsToEnd() {
        // offset 999 on a 5-char string → same as offset 5
        assertEquals(PositionConverter.toPosition("hello", 5),
                     PositionConverter.toPosition("hello", 999));
    }

    @Test
    void toPosition_emptyString() {
        assertEquals(pos(0, 0), PositionConverter.toPosition("", 0));
    }

    // ─── Round-trips ─────────────────────────────────────────────────────────

    /**
     * For every character position in the code, converting to an LSP position
     * and back must return the original offset.
     */
    @Test
    void roundTrip_offsetToPositionAndBack() {
        String code = "public class Foo {\n    void bar() {\n        return;\n    }\n}\n";
        for (int offset = 0; offset <= code.length(); offset++) {
            Position p = PositionConverter.toPosition(code, offset);
            int recovered = PositionConverter.toOffset(code, p);
            assertEquals(offset, recovered,
                    "Round-trip failed at offset " + offset);
        }
    }

    /**
     * For every (line, char) position that names a real character, converting
     * to an offset and back must return the original position.
     */
    @Test
    void roundTrip_positionToOffsetAndBack() {
        String code = "one\ntwo\nthree\n";
        String[] lines = code.split("\n", -1);
        for (int line = 0; line < lines.length; line++) {
            for (int ch = 0; ch <= lines[line].length(); ch++) {
                Position original = pos(line, ch);
                int offset = PositionConverter.toOffset(code, original);
                Position recovered = PositionConverter.toPosition(code, offset);
                assertEquals(original, recovered,
                        "Round-trip failed at (" + line + "," + ch + ")");
            }
        }
    }

    // ─── Helper ──────────────────────────────────────────────────────────────

    private static Position pos(int line, int character) {
        return new Position(line, character);
    }
}
