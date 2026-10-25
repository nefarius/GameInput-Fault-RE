// Read-only export of the imported analysis. Generated output belongs under artifacts/.
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.util.*;
import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.*;
import ghidra.program.model.address.*;
import ghidra.program.model.listing.*;
import ghidra.program.model.scalar.Scalar;
import ghidra.program.model.symbol.*;

public class ExportXinputEvidence extends GhidraScript {
    private PrintWriter writer(File f) throws Exception {
        return new PrintWriter(f, StandardCharsets.UTF_8);
    }
    public void run() throws Exception {
        String[] args = getScriptArgs();
        if (args.length < 1) throw new IllegalArgumentException("Expected output directory [exact] [function address ...]");
        boolean exact = args.length > 1 && args[1].equals("exact");
        int firstAddress = exact ? 2 : 1;
        if (exact && args.length == 2) throw new IllegalArgumentException("exact requires function addresses");
        File out = new File(args[0]); out.mkdirs();
        Set<Function> selected = new LinkedHashSet<>();
        try (PrintWriter w = writer(new File(out, "inventory.txt"))) {
            w.println("Program: " + currentProgram.getName());
            w.println("Executable SHA256: " + currentProgram.getExecutableSHA256());
            w.println("Image base: " + currentProgram.getImageBase());
            w.println("Language: " + currentProgram.getLanguageID());
            var info = currentProgram.getOptions(Program.PROGRAM_INFO);
            for (String key : info.getOptionNames())
                w.println(key + ": " + info.getValueAsString(key));
            for (Function f : currentProgram.getFunctionManager().getFunctions(true)) {
                w.println(f.getEntryPoint() + " " + f.getName() + " " + f.getBody());
                if (args.length == 1 && f.getName().matches("(?i).*(ioctl|state|rumble|vibr|report|read|write|focus|queue|devicecontrol).*")) selected.add(f);
            }
            for (Instruction ins : currentProgram.getListing().getInstructions(true)) {
                for (int i = 0; i < ins.getNumOperands(); i++) {
                    for (Object obj : ins.getOpObjects(i)) {
                        if (obj instanceof Scalar && (((Scalar)obj).getUnsignedValue() & 0xffffffffL) == 0x8000e388L) {
                            Function f = getFunctionContaining(ins.getAddress());
                            w.println("IOCTL_LITERAL " + ins.getAddress() + " " + ins + " in " + f);
                            if (f != null && !exact) selected.add(f);
                        }
                    }
                }
            }
        }
        for (int i = firstAddress; i < args.length; i++) {
            Function f = getFunctionContaining(toAddr(args[i]));
            if (f == null) throw new IllegalArgumentException("No function at " + args[i]);
            selected.add(f);
        }
        DecompInterface dec = new DecompInterface();
        dec.openProgram(currentProgram);
        try {
            for (Function f : selected) {
                monitor.checkCancelled();
                File file = new File(out, f.getEntryPoint() + ".txt");
                try (PrintWriter w = writer(file)) {
                    w.println("FUNCTION " + f.getEntryPoint() + " " + f.getName());
                    w.println("BODY " + f.getBody());
                    w.println("INCOMING REFERENCES");
                    for (Reference ref : getReferencesTo(f.getEntryPoint()))
                        w.println(ref + " caller=" + getFunctionContaining(ref.getFromAddress()));
                    w.println("DIRECT CALLEES");
                    for (Function callee : f.getCalledFunctions(monitor))
                        w.println(callee.getEntryPoint() + " " + callee.getName());
                    DecompileResults result = dec.decompileFunction(f, 90, monitor);
                    w.println("DECOMPILATION completed=" + result.decompileCompleted() + " error=" + result.getErrorMessage());
                    if (result.getDecompiledFunction() != null) w.println(result.getDecompiledFunction().getC());
                    w.println("INSTRUCTIONS (analysis bytes, not runtime)");
                    for (Instruction ins : currentProgram.getListing().getInstructions(f.getBody(), true)) {
                        StringJoiner refs = new StringJoiner("; ");
                        for (Reference ref : ins.getReferencesFrom()) refs.add(ref.toString());
                        w.println(ins.getAddress() + " " + HexFormat.of().formatHex(ins.getBytes()) + " " + ins + " | " + refs);
                    }
                }
                println("Exported " + f.getEntryPoint() + " " + f.getName());
            }
        } finally { dec.dispose(); }
    }
}
