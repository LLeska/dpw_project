param([string]$EquationFile)

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
                    [System.IO.FileShare]::ReadWrite
                )
                $s.Close()
                return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
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
    $helperDir = Join-Path $env:LOCALAPPDATA "SWEquationWatcher\v9-safe"
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
        if (args == null || args.Length != 1 || String.IsNullOrWhiteSpace(args[0]))
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

        List<FileVariable> fileVariables = ReadGlobalVariables(equationsPath);

        ISldWorks swApp;

        try
        {
            object running = Marshal.GetActiveObject("SldWorks.Application");
            swApp = running as ISldWorks;

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
        int addedVariables = 0;
        int addErrors = 0;
        int refreshTrue = 0;
        int refreshFalse = 0;
        int refreshErrors = 0;
        int rebuildErrors = 0;

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

                // SAFE MODE: never mutate the equation manager and never re-link/re-export.
                // The watched equations.txt is strictly read-only from this helper's point of view.
                // Only existing linked equations are refreshed from the external file.

                try
                {
                    bool ok = eq.UpdateValuesFromExternalEquationFile();

                    if (ok)
                        refreshTrue++;
                    else
                        refreshFalse++;
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

        for (int pass = 1; pass <= 2; pass++)
        {
            foreach (IModelDoc2 model in docs)
            {
                try
                {
                    model.ForceRebuild3(false);
                }
                catch
                {
                    rebuildErrors++;
                }
            }
        }

        Console.WriteLine(
            "Done. Open docs=" + docs.Count +
            ", linked to watched file=" + linkedDocs +
            ", skipped=" + skippedDocs +
            ", new globals added=" + addedVariables +
            ", add errors=" + addErrors +
            ", equation refresh OK=" + refreshTrue +
            ", equation returned false=" + refreshFalse +
            ", refresh errors=" + refreshErrors +
            ", rebuild errors=" + rebuildErrors + "."
        );

        return (addErrors == 0 && refreshErrors == 0 && rebuildErrors == 0) ? 0 : 4;
    }

    private static string SafeTitle(IModelDoc2 model)
    {
        try { return model.GetTitle(); }
        catch { return "<unknown>"; }
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

    Log "Building SolidWorks helper v7..."

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

$interop = Find-SolidWorksInterop

if ([string]::IsNullOrWhiteSpace($interop)) {
    Write-Host "Could not find SolidWorks.Interop.sldworks.dll."
    Read-Host "Press Enter to exit"
    exit 1
}

Log "Using SolidWorks interop:"
Write-Host "  $interop"

try {
    $helperExe = Build-Helper $interop
}
catch {
    Write-Host "Failed to build helper:"
    Write-Host $_.Exception.Message
    Read-Host "Press Enter to exit"
    exit 1
}

Log "Helper ready:"
Write-Host "  $helperExe"

if ([string]::IsNullOrWhiteSpace($EquationFile)) {
    $defaultEquationFile = Join-Path $PSScriptRoot "equations.txt"

    if (Test-Path -LiteralPath $defaultEquationFile) {
        Write-Host ""
        Write-Host "Found equations.txt next to the watcher:"
        Write-Host "  $defaultEquationFile"

        $answer = Read-Host "Use this file? [Y/n]"

        $useDefault = (
            [string]::IsNullOrWhiteSpace($answer) -or
            $answer -match '^(?i:y|yes|д|да)$'
        )

        if ($useDefault) {
            $EquationFile = $defaultEquationFile
        }
        else {
            $EquationFile = Read-Host "Full path to equations.txt"
        }
    }
    else {
        $EquationFile = Read-Host "Full path to equations.txt"
    }
}

try {
    $resolved = Resolve-Path -LiteralPath $EquationFile
    $EquationFile = $resolved.ProviderPath
}
catch {
    Write-Host "File not found: $EquationFile"
    Read-Host "Press Enter to exit"
    exit 1
}

try {
    $lastHash = StableHash $EquationFile
}
catch {
    Write-Host "Cannot initially read equations file: $EquationFile"
    Write-Host $_.Exception.Message
    Read-Host "Press Enter to exit"
    exit 1
}

Log "Watching by polling: $EquationFile"
Log "On change: add missing globals, refresh linked equations, rebuild documents."
Log "Polling interval: 0.5 s. Ctrl+C stops the watcher."

while ($true) {
    Start-Sleep -Milliseconds 500

    try {
        $newHash = StableHash $EquationFile
    }
    catch {
        # Network share can briefly be unavailable during save/reconnect.
        continue
    }

    if ($newHash -eq $lastHash) {
        continue
    }

    $lastHash = $newHash
    Log "equations.txt changed -> synchronizing SolidWorks"

    try {
        $output = & $helperExe $EquationFile 2>&1

        foreach ($line in @($output)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$line)) {
                Log ([string]$line)
            }
        }

        if ($LASTEXITCODE -ne 0) {
            Log "Helper exit code: $LASTEXITCODE"
        }
    }
    catch {
        Log "Could not run helper: $($_.Exception.Message)"
    }
}
