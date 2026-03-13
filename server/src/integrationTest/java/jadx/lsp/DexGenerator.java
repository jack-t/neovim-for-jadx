package jadx.lsp;

import java.io.IOException;
import java.io.InputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Objects;

/**
 * Utility to load test DEX files for integration testing.
 *
 * Uses a pre-built DEX file containing the Hello and Caller classes.
 * The DEX was assembled using the smali command-line tool.
 */
public class DexGenerator {

    /**
     * Generates (or loads) a test DEX file and returns its path.
     * Uses a pre-built minimal DEX embedded in test resources.
     *
     * @param resourceName ignored - uses embedded test.dex
     * @return path to the .dex file
     * @throws IOException if file operations fail
     */
    public static Path generateDexFromResource(String resourceName) throws IOException {
        // Create temp directory
        Path tempDir = Files.createTempDirectory("dex-test-");
        Path outputDexFile = tempDir.resolve("test.dex");

        // Load pre-built DEX from resources
        byte[] dexBytes = loadEmbeddedDex();

        // Write to disk
        Files.write(outputDexFile, dexBytes);
        return outputDexFile;
    }

    /**
     * Loads the pre-built test DEX file from classpath resources.
     * This DEX contains the Hello and Caller classes compiled from smali.
     */
    private static byte[] loadEmbeddedDex() throws IOException {
        try (InputStream is = DexGenerator.class.getClassLoader()
                .getResourceAsStream("test.dex")) {
            if (is == null) {
                throw new IOException("test.dex not found in classpath resources");
            }
            return is.readAllBytes();
        }
    }
}
