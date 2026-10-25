// Explicit matching PDB, without force-loading mismatched symbols or network search.
import java.io.File;
import ghidra.app.script.GhidraScript;
import ghidra.app.plugin.core.analysis.PdbUniversalAnalyzer;
import ghidra.app.util.bin.format.pdb2.pdbreader.*;
import pdb.symbolserver.SymbolFileInfo;

public class SetXinputPdb extends GhidraScript {
    public void run() throws Exception {
        String[] args = getScriptArgs();
        if (args.length != 1) throw new IllegalArgumentException("Expected matching PDB path");
        PdbIdentifiers expected = SymbolFileInfo.fromProgramInfo(currentProgram).getIdentifiers();
        try (AbstractPdb pdb = PdbParser.parse(new File(args[0]), new PdbReaderOptions(), monitor)) {
            PdbIdentifiers actual = pdb.getIdentifiers();
            println("PE PDB identity: " + expected);
            println("File PDB identity: " + actual);
            if (expected.getGuid() == null || actual.getGuid() == null ||
                !expected.getGuid().toString().equalsIgnoreCase(actual.getGuid().toString()) ||
                expected.getAge() != actual.getAge())
                throw new IllegalArgumentException("PDB GUID/age mismatch");
            println("PDB GUID and age MATCH");
        }
        PdbUniversalAnalyzer.setPdbFileOption(currentProgram, new File(args[0]));
        println("Explicit PDB: " + new File(args[0]).getCanonicalPath());
    }
}
