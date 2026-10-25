// Local analysis of a target for which no matching public PDB is available.
import ghidra.app.script.GhidraScript;
public class DisablePdb extends GhidraScript {
    public void run() throws Exception {
        setAnalysisOption(currentProgram, "PDB Universal", "false");
        println("Disabled PDB Universal for this program; no PDB applied by this script.");
    }
}
