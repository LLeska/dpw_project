param(
    [string]$EquationFile = (Join-Path $PSScriptRoot "equations.txt"),
    [switch]$Once,
    [switch]$Inspect,
    [switch]$BuildOnly
)

$ErrorActionPreference = "Stop"

function Log([string]$m) {
    Write-Host ("[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $m)
}

function StableHash([string]$Path) {
    for ($i = 0; $i -lt 25; $i++) {
        try {
            if (Test-Path -LiteralPath $Path) {
                $s = [System.IO.File]::Open(
                    $Path,
                    [System.IO.FileMode]::Open,
                    [System.IO.FileAccess]::Read,
                    ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
                )
                try {
                    if ($s.Length -eq 0) { throw "Equations file is empty." }
                    $sha = [System.Security.Cryptography.SHA256]::Create()
                    try {
                        return [BitConverter]::ToString($sha.ComputeHash($s)).Replace('-', '')
                    } finally { $sha.Dispose() }
                } finally { $s.Dispose() }
            }
        } catch {}
        Start-Sleep -Milliseconds 120
    }

    throw "Cannot read equations file: $Path"
}

function Find-SolidWorksInterop {
    $candidates = @(
        "C:\Program Files\SOLIDWORKS Corp\SOLIDWORKS\SolidWorks.Interop.sldworks.dll",
        "C:\Program Files\SOLIDWORKS Corp\SOLIDWORKS\api\redist\SolidWorks.Interop.sldworks.dll",
        "C:\Program Files\SOLIDWORKS Corp\SOLIDWORKS\api\SolidWorks.Interop.sldworks.dll"
    )

    foreach ($p in $candidates) {
        if (Test-Path -LiteralPath $p) {
            return (Resolve-Path -LiteralPath $p).Path
        }
    }

    return $null
}

function Find-CSharpCompiler {
    $candidates = @(
        "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe",
        "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319\csc.exe"
    )

    foreach ($p in $candidates) {
        if (Test-Path -LiteralPath $p) {
            return $p
        }
    }

    return $null
}

function Build-Helper([string]$InteropPath) {
    $helperDir = Join-Path $PSScriptRoot ".watch-equations"
    New-Item -ItemType Directory -Force -Path $helperDir | Out-Null

    $localInterop = Join-Path $helperDir "SolidWorks.Interop.sldworks.dll"
    $sourcePath = Join-Path $helperDir "SwEquationsHelper.cs"
    $exePath = Join-Path $helperDir "sw-equations-helper.exe"

    Copy-Item -LiteralPath $InteropPath -Destination $localInterop -Force

    $source = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using System.Text;
using System.Text.RegularExpressions;
using SolidWorks.Interop.sldworks;

internal static class Program
{
    private sealed class FileVariable
    {
        public string Name;
        public string EquationLine;
    }

    [STAThread]
    private static int Main(string[] args)
    {
        if (args == null || args.Length < 1 || String.IsNullOrWhiteSpace(args[0]))
        {
            Console.WriteLine("ERROR: equations.txt path was not supplied.");
            return 10;
        }

        string equationsPath = Path.GetFullPath(args[0]);

        if (!File.Exists(equationsPath))
        {
            Console.WriteLine("ERROR: equations file does not exist: " + equationsPath);
            return 10;
        }

        bool inspect = args.Length > 1 && args[1] == "--inspect";
        ReadGlobalVariables(equationsPath); // Reject an unreadable source before touching models.

        ISldWorks swApp;

        try
        {
            swApp = ConnectToSolidWorks();

            if (swApp == null)
            {
                Console.WriteLine("ERROR: Running SolidWorks object does not expose ISldWorks.");
                return 2;
            }
        }
        catch (Exception ex)
        {
            Console.WriteLine("ERROR: Cannot connect to running SolidWorks: " + ex.Message);
            return 2;
        }

        object docsRaw = swApp.GetDocuments();
        Array docsArray = docsRaw as Array;

        if (docsArray == null)
        {
            Console.WriteLine("ERROR: GetDocuments returned no array.");
            return 3;
        }

        var docs = new List<IModelDoc2>();

        foreach (object item in docsArray)
        {
            IModelDoc2 model = item as IModelDoc2;
            if (model != null)
                docs.Add(model);
        }

        int linkedDocs = 0;
        int skippedDocs = 0;
        int refreshTrue = 0;
        int refreshFalse = 0;
        int refreshErrors = 0;
        int rebuildErrors = 0;
        var linkedModels = new List<IModelDoc2>();

        foreach (IModelDoc2 model in docs)
        {
            string title = SafeTitle(model);

            try
            {
                IEquationMgr eq = model.GetEquationMgr();

                if (eq == null)
                {
                    skippedDocs++;
                    continue;
                }

                bool linked;
                string linkedPath;

                try
                {
                    linked = eq.LinkToFile;
                    linkedPath = eq.FilePath ?? "";
                }
                catch
                {
                    skippedDocs++;
                    continue;
                }

                if (!linked || !SamePath(linkedPath, equationsPath))
                {
                    skippedDocs++;
                    continue;
                }

                linkedDocs++;
                linkedModels.Add(model);

                if (inspect)
                {
                    Console.WriteLine("LINKED: " + title + " -> " + linkedPath);
                    for (int i = 0; i < eq.GetCount(); i++)
                    {
                        string line = eq.get_Equation(i);
                        if (eq.get_GlobalVariable(i) && (ParseLeftHandQuotedName(line) == "Высота пола" ||
                            ParseLeftHandQuotedName(line) == "Толщина стенки"))
                            Console.WriteLine("  " + line + " | value=" + eq.get_Value(i));
                    }
                    continue;
                }

                // SAFE MODE: never mutate the equation manager and never re-link/re-export.
                // The watched equations.txt is strictly read-only from this helper's point of view.
                // Only existing linked equations are refreshed from the external file.

                try
                {
                    bool ok = eq.UpdateValuesFromExternalEquationFile();

                    if (ok)
                    {
                        refreshTrue++;
                        Console.WriteLine("UPDATED: " + title);
                    }
                    else
                    {
                        refreshFalse++;
                        Console.WriteLine("ERROR: Equation refresh returned false for '" + title + "'.");
                    }
                }
                catch (Exception ex)
                {
                    refreshErrors++;
                    Console.WriteLine(
                        "Equation refresh failed for '" + title + "': " + ex.Message
                    );
                }
            }
            catch (Exception ex)
            {
                refreshErrors++;
                Console.WriteLine(
                    "Equation processing failed for '" + title + "': " + ex.Message
                );
            }
        }

        if (linkedDocs == 0)
        {
            Console.WriteLine("ERROR: No open documents are linked to " + equationsPath);
            return 5;
        }

        // Refresh every linked equation first, then rebuild parts before assemblies.
        // Unrelated open documents must not be rebuilt by this watcher.
        if (!inspect && refreshFalse == 0 && refreshErrors == 0)
        for (int type = 1; type <= 2; type++)
        {
            foreach (IModelDoc2 model in linkedModels)
            {
                try
                {
                    if (model.GetType() != type) continue;
                    if (!model.ForceRebuild3(false))
                    {
                        rebuildErrors++;
                        Console.WriteLine("ERROR: Rebuild returned false for '" + SafeTitle(model) + "'.");
                    }
                }
                catch (Exception ex)
                {
                    rebuildErrors++;
                    Console.WriteLine("ERROR: Rebuild failed for '" + SafeTitle(model) + "': " + ex.Message);
                }
            }
        }

        Console.WriteLine(
            "Done. Open docs=" + docs.Count +
            ", linked to watched file=" + linkedDocs +
            ", skipped=" + skippedDocs +
            ", equation refresh OK=" + refreshTrue +
            ", equation returned false=" + refreshFalse +
            ", refresh errors=" + refreshErrors +
            ", rebuild errors=" + rebuildErrors + "."
        );

        return (refreshFalse == 0 && refreshErrors == 0 && rebuildErrors == 0) ? 0 : 4;
    }

    private static string SafeTitle(IModelDoc2 model)
    {
        try { return model.GetTitle(); }
        catch { return "<unknown>"; }
    }

    [DllImport("ole32.dll")]
    private static extern int GetRunningObjectTable(int reserved, out IRunningObjectTable table);

    [DllImport("ole32.dll")]
    private static extern int CreateBindCtx(int reserved, out IBindCtx context);

    private static ISldWorks ConnectToSolidWorks()
    {
        try
        {
            ISldWorks active = Marshal.GetActiveObject("SldWorks.Application") as ISldWorks;
            if (active != null) return active;
        }
        catch (COMException) { }

        // Some sessions publish only a process-specific SolidWorks ROT moniker.
        // Attach to the existing application; never create another SolidWorks instance.
        IRunningObjectTable table = null;
        IBindCtx context = null;
        IEnumMoniker enumerator = null;
        ISldWorks found = null;
        try
        {
            Marshal.ThrowExceptionForHR(GetRunningObjectTable(0, out table));
            Marshal.ThrowExceptionForHR(CreateBindCtx(0, out context));
            table.EnumRunning(out enumerator);
            var item = new IMoniker[1];
            while (enumerator.Next(1, item, IntPtr.Zero) == 0)
            {
                try
                {
                    string name;
                    item[0].GetDisplayName(context, null, out name);
                    if (!name.StartsWith("SolidWorks_PID_", StringComparison.OrdinalIgnoreCase)) continue;
                    object running;
                    table.GetObject(item[0], out running);
                    ISldWorks candidate = running as ISldWorks;
                    if (candidate == null) continue;
                    if (found != null)
                        throw new InvalidOperationException("Multiple SolidWorks instances are running; close the unused instance.");
                    found = candidate;
                }
                finally { Marshal.ReleaseComObject(item[0]); }
            }
        }
        finally
        {
            if (enumerator != null) Marshal.ReleaseComObject(enumerator);
            if (context != null) Marshal.ReleaseComObject(context);
            if (table != null) Marshal.ReleaseComObject(table);
        }
        if (found == null)
            throw new InvalidOperationException("Cannot attach to running SolidWorks. Run the watcher in the same Windows session and at the same privilege level as SolidWorks.");
        return found;
    }

    private static bool SamePath(string a, string b)
    {
        if (String.IsNullOrWhiteSpace(a) || String.IsNullOrWhiteSpace(b))
            return false;

        try
        {
            string pa = Path.GetFullPath(a).TrimEnd('\\');
            string pb = Path.GetFullPath(b).TrimEnd('\\');

            return String.Equals(pa, pb, StringComparison.OrdinalIgnoreCase);
        }
        catch
        {
            return String.Equals(
                a.Trim(),
                b.Trim(),
                StringComparison.OrdinalIgnoreCase
            );
        }
    }

    private static HashSet<string> GetExistingGlobalVariables(IEquationMgr eq)
    {
        var result = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        int count = eq.GetCount();

        for (int i = 0; i < count; i++)
        {
            try
            {
                if (!eq.get_GlobalVariable(i))
                    continue;

                string equation = eq.get_Equation(i);
                string name = ParseLeftHandQuotedName(equation);

                if (!String.IsNullOrWhiteSpace(name))
                    result.Add(name);
            }
            catch { }
        }

        return result;
    }

    private static List<FileVariable> ReadGlobalVariables(string path)
    {
        string[] lines = ReadAllLinesAutoEncoding(path);

        var vars = new List<FileVariable>();
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        foreach (string original in lines)
        {
            if (original == null)
                continue;

            string line = original.Trim();

            if (line.Length == 0 ||
                line.StartsWith("//") ||
                line.StartsWith("#") ||
                line.StartsWith(";"))
                continue;

            string name = ParseLeftHandQuotedName(line);

            if (String.IsNullOrWhiteSpace(name))
                continue;

            // Dimensions are normally "D1@Sketch1" etc.
            if (name.IndexOf('@') >= 0)
                continue;

            if (seen.Add(name))
            {
                vars.Add(new FileVariable
                {
                    Name = name,
                    EquationLine = line
                });
            }
        }

        return vars;
    }

    private static string ParseLeftHandQuotedName(string equation)
    {
        if (String.IsNullOrWhiteSpace(equation))
            return null;

        Match m = Regex.Match(
            equation,
            "^\\s*\"(?<name>[^\"]+)\"\\s*="
        );

        return m.Success ? m.Groups["name"].Value : null;
    }

    private static string[] ReadAllLinesAutoEncoding(string path)
    {
        byte[] data = File.ReadAllBytes(path);

        if (data.Length >= 3 &&
            data[0] == 0xEF &&
            data[1] == 0xBB &&
            data[2] == 0xBF)
            return File.ReadAllLines(path, new UTF8Encoding(true, true));

        try
        {
            string text = new UTF8Encoding(false, true).GetString(data);
            return Regex.Split(text, "\\r\\n|\\n|\\r");
        }
        catch (DecoderFallbackException)
        {
            string text = Encoding.Default.GetString(data);
            return Regex.Split(text, "\\r\\n|\\n|\\r");
        }
    }
}
'@

    Set-Content -LiteralPath $sourcePath -Value $source -Encoding UTF8

    $csc = Find-CSharpCompiler

    if ([string]::IsNullOrWhiteSpace($csc)) {
        throw "Could not find .NET Framework csc.exe."
    }

    Log "Building SolidWorks equations helper..."

    $compilerOutput = & $csc `
        /nologo `
        /target:exe `
        /platform:x64 `
        "/out:$exePath" `
        "/reference:$localInterop" `
        $sourcePath 2>&1

    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $exePath)) {
        $text = ($compilerOutput | Out-String).Trim()
        throw "C# helper compilation failed.`n$text"
    }

    return $exePath
}

function Watch-EquationFile {
    param(
        [string]$Path,
        [scriptblock]$Synchronize,
        [switch]$SinglePass,
        [int]$PollMilliseconds = 500,
        [int]$SettleMilliseconds = 700,
        [int]$RetryMilliseconds = 5000,
        [scriptblock]$ShouldStop = { $false }
    )

    $appliedHash = $null
    $candidateHash = $null
    $stableSince = [DateTime]::UtcNow
    $nextAttempt = [DateTime]::MinValue

    while (-not (& $ShouldStop)) {
        try {
            $hash = StableHash $Path
        } catch {
            if ($SinglePass) { throw }
            Start-Sleep -Milliseconds $PollMilliseconds
            continue
        }

        $now = [DateTime]::UtcNow
        if ($hash -ne $candidateHash) {
            $candidateHash = $hash
            $stableSince = $now
            $nextAttempt = [DateTime]::MinValue
        }

        if ($hash -ne $appliedHash -and
            ($now - $stableSince).TotalMilliseconds -ge $SettleMilliseconds -and
            $now -ge $nextAttempt) {
            Log 'Synchronizing equations with SolidWorks...'
            $success = $false
            try { $success = [bool](& $Synchronize) }
            catch { Log "Synchronization failed: $($_.Exception.Message)" }

            if ($success) {
                # A failed attempt must never consume a file change.
                # If the file changed during synchronization, the next pass applies it too.
                $appliedHash = $hash
                Log 'Equations applied successfully.'
                if ($SinglePass -and (StableHash $Path) -eq $appliedHash) { return 0 }
            } else {
                Log 'Not applied. The same file version will be retried.'
                if ($SinglePass) { return 4 }
                $nextAttempt = [DateTime]::UtcNow.AddMilliseconds($RetryMilliseconds)
            }
        }
        Start-Sleep -Milliseconds $PollMilliseconds
    }
    return 0
}

function Start-EquationWatcher {
    param([string]$Path, [switch]$SinglePass, [switch]$ReadOnly, [switch]$CompileOnly)

    $resolvedPath = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath
    $interop = Find-SolidWorksInterop
    if ([string]::IsNullOrWhiteSpace($interop)) {
        throw 'Could not find SolidWorks.Interop.sldworks.dll.'
    }

    # Only one watcher (or one-shot update) may use this file at a time.
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $key = [BitConverter]::ToString($sha.ComputeHash(
            [Text.Encoding]::UTF8.GetBytes($resolvedPath.ToUpperInvariant())
        )).Replace('-', '')
    } finally { $sha.Dispose() }
    $mutex = New-Object Threading.Mutex($false, "Local\SWEquationWatcher_$key")
    $owned = $false
    $connectionState = @{ Lease = $null }
    try {
        try { $owned = $mutex.WaitOne(0) }
        catch [Threading.AbandonedMutexException] { $owned = $true }
        if (-not $owned) { throw 'Another watcher is already using this equations file.' }

        $helperExe = Build-Helper $interop
        Log "Helper ready: $helperExe"
        if ($CompileOnly) { return 0 }

        if (-not ('SwEquationConnection' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class SwEquationConnection {
    [DllImport("oleaut32.dll", PreserveSig = false)]
    private static extern void GetActiveObject(ref Guid classId, IntPtr reserved,
        [MarshalAs(UnmanagedType.IUnknown)] out object instance);
    public static object Attach() {
        Guid classId = Type.GetTypeFromProgID("SldWorks.Application", true).GUID;
        object instance;
        GetActiveObject(ref classId, IntPtr.Zero, out instance);
        return instance;
    }
}
'@
        }

        if ($ReadOnly) {
            $connectionState.Lease = [SwEquationConnection]::Attach()
            & $helperExe $resolvedPath '--inspect' | ForEach-Object { Log ([string]$_) }
            return $LASTEXITCODE
        }

        $sync = {
            # Keep the application COM object alive between short-lived helper calls.
            # A weak ROT registration otherwise disappears when the helper exits.
            if ($null -eq $connectionState.Lease) {
                $connectionState.Lease = [SwEquationConnection]::Attach()
            }
            $output = & $helperExe $resolvedPath 2>&1
            $helperExitCode = $LASTEXITCODE
            foreach ($line in @($output)) {
                if (-not [string]::IsNullOrWhiteSpace([string]$line)) { Log ([string]$line) }
            }
            if ($helperExitCode -ne 0) { Log "Helper exit code: $helperExitCode" }
            if ($helperExitCode -eq 2 -and $null -ne $connectionState.Lease) {
                [void][Runtime.InteropServices.Marshal]::ReleaseComObject($connectionState.Lease)
                $connectionState.Lease = $null
            }
            return ($helperExitCode -eq 0)
        }.GetNewClosure()

        Log "Equations file: $resolvedPath"
        Log 'Apply at startup, then watch changes. Ctrl+C stops the watcher.'
        return (Watch-EquationFile -Path $resolvedPath -Synchronize $sync -SinglePass:$SinglePass)
    } finally {
        if ($null -ne $connectionState.Lease) {
            [void][Runtime.InteropServices.Marshal]::ReleaseComObject($connectionState.Lease)
        }
        if ($owned) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

# Dot-sourcing loads functions for focused tests without connecting to SolidWorks.
if ($MyInvocation.InvocationName -ne '.') {
    try {
        exit (Start-EquationWatcher -Path $EquationFile -SinglePass:$Once -ReadOnly:$Inspect -CompileOnly:$BuildOnly)
    } catch {
        Write-Error $_ -ErrorAction Continue
        exit 1
    }
}
