<#
.SYNOPSIS
Comprime file o cartelle in uno zip e lo trasforma in testo base64, e viceversa.

.DESCRIPTION
Versione PowerShell di b64pack.py con lo stesso formato: il testo prodotto da una delle
due versioni si decodifica con l'altra. Funziona con Windows PowerShell 5.1 e PowerShell 7.

Il testo e' base64 puro a righe di 76 caratteri. -Split spezza il flusso in parti
(nome.zip.b64.part1of3.txt, ...) che, concatenate in ordine, sono il testo intero.

.EXAMPLE
.\b64pack.ps1 pack contratto.pdf

.EXAMPLE
.\b64pack.ps1 pack C:\dev\biblioteca -Split 1

.EXAMPLE
.\b64pack.ps1 unpack biblioteca.zip.b64.part1of3.txt -Extract biblioteca
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('pack', 'unpack')]
    [string]$Command,

    [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
    [string[]]$Path,

    [Alias('o')]
    [string]$Output,

    [double]$Split = 0,

    [Alias('x')]
    [string]$Extract,

    [switch]$All,
    [switch]$Copy,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression

$LineWidth = 76

# Mai utili in un archivio di sorgenti: controllo versione, IDE, cache.
$AlwaysSkippedDirs = @('.git', '.svn', '.hg', '.idea', '.vscode', '.gradle', 'node_modules', '__pycache__', '__MACOSX')
$AlwaysSkippedFiles = @('.DS_Store', 'Thumbs.db')
$SkippedFilePatterns = @('*.class')

# target/, build/ e out/ si saltano solo accanto a un file di build: altrove
# (per esempio src/main/java/com/acme/build) possono essere un package vero.
$BuildOutputDirs = @('target', 'build', 'out')
$BuildFiles = @('pom.xml', 'build.gradle', 'build.gradle.kts', 'settings.gradle', 'settings.gradle.kts', 'build.xml')

$PartPattern = '^(?<prefix>.+)\.part(?<index>\d+)of(?<total>\d+)\.txt$'

# .NET Framework non verifica il CRC dei file dello zip in lettura: lo calcoliamo noi.
if (-not ('B64PackCrc32' -as [type])) {
    try {
        Add-Type -TypeDefinition @'
public static class B64PackCrc32
{
    private static readonly uint[] Table = BuildTable();

    private static uint[] BuildTable()
    {
        uint[] table = new uint[256];
        for (uint i = 0; i < 256; i++)
        {
            uint c = i;
            for (int k = 0; k < 8; k++)
            {
                c = (c & 1) != 0 ? 0xEDB88320u ^ (c >> 1) : c >> 1;
            }
            table[i] = c;
        }
        return table;
    }

    public static uint Update(uint crc, byte[] buffer, int count)
    {
        crc = ~crc;
        for (int i = 0; i < count; i++)
        {
            crc = Table[(crc ^ buffer[i]) & 0xFF] ^ (crc >> 8);
        }
        return ~crc;
    }
}
'@
    }
    catch {
    }
}
$CanCheckCrc = [bool]('B64PackCrc32' -as [type])

$Cwd = (Get-Location).ProviderPath


function Fail([string]$Message) {
    [Console]::Error.WriteLine("b64pack: errore: $Message")
    exit 1
}

function Say([string]$Message) {
    [Console]::Out.WriteLine($Message)
}

function Format-Size([double]$Size) {
    $invariant = [Globalization.CultureInfo]::InvariantCulture
    foreach ($unit in 'B', 'KB', 'MB', 'GB') {
        if ($Size -lt 1024 -or $unit -eq 'GB') {
            if ($unit -eq 'B') {
                return $Size.ToString('0', $invariant) + ' B'
            }
            return $Size.ToString('0.0', $invariant) + " $unit"
        }
        $Size = $Size / 1024
    }
}

function Get-Sha256Hex([byte[]]$Data) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return [BitConverter]::ToString($sha.ComputeHash($Data)).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Get-FullPath([string]$Item) {
    $full = [IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Item))
    $trimmed = $full.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    if ($trimmed -eq '' -or $trimmed.EndsWith(':')) {
        return $full
    }
    return $trimmed
}

function Show-Path([string]$Full) {
    $prefix = $Cwd.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if ($Full.StartsWith($prefix, [StringComparison]::Ordinal)) {
        return $Full.Substring($prefix.Length)
    }
    return $Full
}

function Resolve-Inputs([string[]]$Items) {
    $result = New-Object System.Collections.Generic.List[string]
    foreach ($item in $Items) {
        if (Test-Path -LiteralPath $item) {
            $result.Add((Get-FullPath $item))
            continue
        }
        if ($item.StartsWith('-')) {
            Fail "parametro sconosciuto: $item (vedi Get-Help .\b64pack.ps1 -Detailed)"
        }
        $found = @(Resolve-Path -Path $item -ErrorAction SilentlyContinue)
        if ($found.Count -eq 0) {
            Fail "non trovo $item"
        }
        foreach ($match in $found) {
            $result.Add((Get-FullPath $match.ProviderPath))
        }
    }
    return $result.ToArray()
}

function Get-SortedNames([string[]]$FullPaths) {
    $names = @($FullPaths | ForEach-Object { [IO.Path]::GetFileName($_) })
    [Array]::Sort($names, [StringComparer]::Ordinal)
    return $names
}


# ---------------------------------------------------------------- pack

function Add-Directory([string]$Dir, [string]$ArcDir, $State) {
    $fileNames = Get-SortedNames ([IO.Directory]::GetFiles($Dir))
    $dirNames = Get-SortedNames ([IO.Directory]::GetDirectories($Dir))
    $hasBuildFile = @($fileNames | Where-Object { $BuildFiles -ccontains $_ }).Count -gt 0

    foreach ($name in $fileNames) {
        $skip = ($AlwaysSkippedFiles -ccontains $name) -or @($SkippedFilePatterns | Where-Object { $name -clike $_ }).Count -gt 0
        if ($skip -and -not $All) {
            $State.SkippedFiles++
            continue
        }
        $State.Entries.Add([pscustomobject]@{ Path = [IO.Path]::Combine($Dir, $name); Name = "$ArcDir/$name" })
    }
    foreach ($name in $dirNames) {
        $full = [IO.Path]::Combine($Dir, $name)
        # Come os.walk di Python: i link a cartelle non si seguono.
        if (([IO.File]::GetAttributes($full) -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            continue
        }
        $skip = ($AlwaysSkippedDirs -ccontains $name) -or ($hasBuildFile -and ($BuildOutputDirs -ccontains $name))
        if ($skip -and -not $All) {
            $State.SkippedDirs.Add("$ArcDir/$name/")
            continue
        }
        Add-Directory $full "$ArcDir/$name" $State
    }
}

function New-ZipBytes($Entries) {
    $buffer = New-Object System.IO.MemoryStream
    $archive = [System.IO.Compression.ZipArchive]::new($buffer, [System.IO.Compression.ZipArchiveMode]::Create, $true)
    $minDate = New-Object DateTime 1980, 1, 1
    $maxDate = New-Object DateTime 2107, 12, 31
    try {
        foreach ($item in $Entries) {
            $entry = $archive.CreateEntry($item.Name, [System.IO.Compression.CompressionLevel]::Optimal)
            $time = [IO.File]::GetLastWriteTime($item.Path)
            if ($time -lt $minDate) { $time = $minDate }
            if ($time -gt $maxDate) { $time = $maxDate }
            $entry.LastWriteTime = New-Object DateTimeOffset $time
            $source = [IO.File]::OpenRead($item.Path)
            $target = $entry.Open()
            try {
                $source.CopyTo($target)
            }
            finally {
                $target.Dispose()
                $source.Dispose()
            }
        }
    }
    finally {
        $archive.Dispose()
    }
    # La virgola evita che PowerShell srotoli il byte[] in migliaia di oggetti.
    return , $buffer.ToArray()
}

function Get-ZipBase([string[]]$Sources) {
    if ($Output) {
        $full = Get-FullPath $Output
        $stem = [IO.Path]::GetFileName($full)
        foreach ($suffix in '.txt', '.b64', '.zip') {
            if ($stem.EndsWith($suffix)) {
                $stem = $stem.Substring(0, $stem.Length - $suffix.Length)
            }
        }
        return [IO.Path]::Combine([IO.Path]::GetDirectoryName($full), $stem + '.zip')
    }
    if ($Sources.Count -gt 1) {
        $stem = 'archivio'
    }
    elseif ([IO.File]::Exists($Sources[0])) {
        $stem = [IO.Path]::GetFileNameWithoutExtension($Sources[0])
        if ($stem -eq '') { $stem = [IO.Path]::GetFileName($Sources[0]) }
    }
    else {
        $stem = [IO.Path]::GetFileName($Sources[0])
    }
    return [IO.Path]::Combine($Cwd, $stem + '.zip')
}

function Get-ExistingOutputs([string]$Base) {
    $found = New-Object System.Collections.Generic.List[string]
    $dir = [IO.Path]::GetDirectoryName($Base)
    $name = [IO.Path]::GetFileName($Base)
    if ([IO.Directory]::Exists($dir)) {
        foreach ($file in [IO.Directory]::GetFiles($dir, "$name.b64.part*of*.txt")) {
            if ([IO.Path]::GetFileName($file).StartsWith("$name.b64.part", [StringComparison]::Ordinal)) {
                $found.Add($file)
            }
        }
    }
    $single = "$Base.b64.txt"
    if ([IO.File]::Exists($single)) {
        $found.Add($single)
    }
    $sorted = $found.ToArray()
    [Array]::Sort($sorted, [StringComparer]::Ordinal)
    return $sorted
}

function Invoke-Pack {
    $sources = @(Resolve-Inputs $Path)
    $base = Get-ZipBase $sources
    $old = @(Get-ExistingOutputs $base)
    if ($old.Count -gt 0 -and -not $Force) {
        Fail ("esiste gia' {0} (usa -Force per sovrascrivere)" -f [IO.Path]::GetFileName($old[0]))
    }
    foreach ($file in $old) {
        [IO.File]::Delete($file)
    }

    $singleZip = $false
    if ($sources.Count -eq 1 -and [IO.File]::Exists($sources[0])) {
        $stream = [IO.File]::OpenRead($sources[0])
        try {
            $probe = [System.IO.Compression.ZipArchive]::new($stream, [System.IO.Compression.ZipArchiveMode]::Read)
            $probe.Dispose()
            $singleZip = $true
        }
        catch {
        }
        finally {
            $stream.Dispose()
        }
    }

    if ($singleZip) {
        $data = [IO.File]::ReadAllBytes($sources[0])
        Say ("{0} e' gia' uno zip: lo codifico cosi' com'e'" -f [IO.Path]::GetFileName($sources[0]))
    }
    else {
        $state = [pscustomobject]@{
            Entries      = New-Object System.Collections.Generic.List[object]
            SkippedDirs  = New-Object System.Collections.Generic.List[string]
            SkippedFiles = 0
        }
        foreach ($src in $sources) {
            if ([IO.File]::Exists($src)) {
                $state.Entries.Add([pscustomobject]@{ Path = $src; Name = [IO.Path]::GetFileName($src) })
            }
            else {
                Add-Directory $src ([IO.Path]::GetFileName($src)) $state
            }
        }
        if ($state.Entries.Count -eq 0) {
            Fail 'nessun file da comprimere'
        }
        $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
        foreach ($item in $state.Entries) {
            if (-not $seen.Add($item.Name)) {
                Fail "due input finirebbero nello zip con lo stesso nome: $($item.Name)"
            }
        }
        $data = New-ZipBytes $state.Entries
        Say ("{0} file compressi" -f $state.Entries.Count)
        if ($state.SkippedDirs.Count -gt 0 -or $state.SkippedFiles -gt 0) {
            $items = New-Object System.Collections.Generic.List[string]
            foreach ($dir in ($state.SkippedDirs | Select-Object -First 8)) {
                $items.Add($dir)
            }
            if ($state.SkippedDirs.Count -gt 8) {
                $items.Add(("altre {0} cartelle" -f ($state.SkippedDirs.Count - 8)))
            }
            if ($state.SkippedFiles -gt 0) {
                $items.Add(("{0} file (.class, .DS_Store)" -f $state.SkippedFiles))
            }
            Say ("esclusi (-All per includerli): {0}" -f ($items -join ', '))
        }
    }

    $text = [Convert]::ToBase64String($data, [Base64FormattingOptions]::InsertLineBreaks).Replace("`r`n", "`n")
    $lines = $text.Split([char]"`n")
    if ($Split -gt 0) {
        $perPart = [Math]::Max(1, [int][Math]::Floor([Math]::Floor($Split * 1048576) / ($LineWidth + 1)))
    }
    else {
        $perPart = $lines.Count
    }
    $partCount = [int][Math]::Ceiling($lines.Count / $perPart)

    $outputs = New-Object System.Collections.Generic.List[string]
    if ($partCount -eq 1) {
        $outputs.Add("$base.b64.txt")
    }
    else {
        $width = "$partCount".Length
        for ($i = 1; $i -le $partCount; $i++) {
            $outputs.Add(('{0}.b64.part{1}of{2}.txt' -f $base, "$i".PadLeft($width, '0'), $partCount))
        }
    }
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($base))
    $ascii = [Text.Encoding]::ASCII
    for ($i = 0; $i -lt $partCount; $i++) {
        $start = $i * $perPart
        $count = [Math]::Min($perPart, $lines.Count - $start)
        [IO.File]::WriteAllText($outputs[$i], [string]::Join("`n", $lines, $start, $count) + "`n", $ascii)
    }

    $written = New-Object System.Text.StringBuilder
    foreach ($file in $outputs) {
        [void]$written.Append([IO.File]::ReadAllText($file, $ascii).Replace("`n", ''))
    }
    $hash = Get-Sha256Hex $data
    if ((Get-Sha256Hex ([Convert]::FromBase64String($written.ToString()))) -ne $hash) {
        Fail 'verifica fallita: il testo scritto non restituisce lo zip'
    }

    $totalText = 0
    foreach ($file in $outputs) {
        $totalText += (New-Object IO.FileInfo $file).Length
    }
    Say ("zip {0}, testo {1} in {2} file:" -f (Format-Size $data.Length), (Format-Size $totalText), $outputs.Count)
    foreach ($file in $outputs) {
        Say ("  {0}" -f (Show-Path $file))
    }
    Say "sha256 dello zip: $hash"

    if ($Copy) {
        if ($outputs.Count -gt 1) {
            Say '-Copy vale solo con un file: copia le parti una alla volta (Get-Content parte -Raw | Set-Clipboard)'
        }
        elseif (Get-Command Set-Clipboard -ErrorAction SilentlyContinue) {
            Set-Clipboard -Value ([IO.File]::ReadAllText($outputs[0], $ascii))
            Say 'testo copiato negli appunti'
        }
        else {
            Say "Set-Clipboard non c'e' su questo sistema: apri il file e copialo a mano"
        }
    }
}


# ---------------------------------------------------------------- unpack

function Resolve-Parts([string[]]$Files) {
    $match = $null
    $index = -1
    for ($i = 0; $i -lt $Files.Count; $i++) {
        $candidate = [regex]::Match([IO.Path]::GetFileName($Files[$i]), $PartPattern)
        if ($candidate.Success) {
            $match = $candidate
            $index = $i
            break
        }
    }
    if ($null -eq $match) {
        if ($Files.Count -gt 1) {
            $keys = @($Files | ForEach-Object { [IO.Path]::GetFileName($_) })
            $sorted = [string[]]$Files.Clone()
            [Array]::Sort([string[]]$keys, $sorted, [StringComparer]::Ordinal)
            return $sorted
        }
        return $Files
    }
    # Con una sola parte indicata trova le altre nella stessa cartella.
    $prefix = $match.Groups['prefix'].Value
    $total = [int]$match.Groups['total'].Value
    $width = $match.Groups['index'].Value.Length
    $folder = [IO.Path]::GetDirectoryName($Files[$index])
    $expected = New-Object System.Collections.Generic.List[string]
    $missing = New-Object System.Collections.Generic.List[string]
    for ($i = 1; $i -le $total; $i++) {
        $name = '{0}.part{1}of{2}.txt' -f $prefix, "$i".PadLeft($width, '0'), $total
        $expected.Add([IO.Path]::Combine($folder, $name))
        if (-not [IO.File]::Exists($expected[$i - 1])) {
            $missing.Add($name)
        }
    }
    if ($missing.Count -gt 0) {
        Fail ("mancano {0} parti su {1}: {2}" -f $missing.Count, $total, ($missing -join ', '))
    }
    return $expected.ToArray()
}

function Get-ZipName([string]$First) {
    $name = [IO.Path]::GetFileName($First)
    $match = [regex]::Match($name, $PartPattern)
    if ($match.Success) {
        $name = $match.Groups['prefix'].Value
    }
    elseif ($name.EndsWith('.txt')) {
        $name = $name.Substring(0, $name.Length - 4)
    }
    if ($name.EndsWith('.b64')) {
        $name = $name.Substring(0, $name.Length - 4)
    }
    if (-not $name.EndsWith('.zip')) {
        $name += '.zip'
    }
    return [IO.Path]::Combine($Cwd, $name)
}

function Get-ZipCrcs([byte[]]$Data) {
    # Legge i CRC dalla directory centrale, nello stesso ordine di ZipArchive.Entries.
    $eocd = -1
    $stop = [Math]::Max(0, $Data.Length - 22 - 65535)
    for ($p = $Data.Length - 22; $p -ge $stop; $p--) {
        if ([BitConverter]::ToUInt32($Data, $p) -eq 0x06054b50) {
            $eocd = $p
            break
        }
    }
    if ($eocd -lt 0) { return $null }
    $count = [BitConverter]::ToUInt16($Data, $eocd + 10)
    $offset = [BitConverter]::ToUInt32($Data, $eocd + 16)
    if ($count -eq [UInt16]::MaxValue -or $offset -eq [UInt32]::MaxValue) { return $null }
    $crcs = New-Object 'System.Collections.Generic.List[UInt32]'
    $p = [long]$offset
    for ($i = 0; $i -lt $count; $i++) {
        if ($p + 46 -gt $Data.Length -or [BitConverter]::ToUInt32($Data, $p) -ne 0x02014b50) { return $null }
        $crcs.Add([BitConverter]::ToUInt32($Data, $p + 16))
        $p += 46 + [BitConverter]::ToUInt16($Data, $p + 28) + [BitConverter]::ToUInt16($Data, $p + 30) + [BitConverter]::ToUInt16($Data, $p + 32)
    }
    return , $crcs.ToArray()
}

function Test-ZipBytes([byte[]]$Data) {
    $crcs = Get-ZipCrcs $Data
    try {
        $archive = [System.IO.Compression.ZipArchive]::new([IO.MemoryStream]::new($Data), [System.IO.Compression.ZipArchiveMode]::Read)
    }
    catch {
        return @{ Broken = '(indice dello zip)'; Count = 0 }
    }
    try {
        $entries = $archive.Entries
        if ($null -eq $crcs -or $crcs.Count -ne $entries.Count) {
            return @{ Broken = '(indice dello zip)'; Count = 0 }
        }
        $buffer = New-Object byte[] 65536
        for ($i = 0; $i -lt $entries.Count; $i++) {
            $entry = $entries[$i]
            $crc = [UInt32]0
            $length = [long]0
            try {
                $stream = $entry.Open()
                try {
                    while (($n = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                        if ($CanCheckCrc) { $crc = [B64PackCrc32]::Update($crc, $buffer, $n) }
                        $length += $n
                    }
                }
                finally {
                    $stream.Dispose()
                }
            }
            catch {
                return @{ Broken = $entry.FullName; Count = $entries.Count }
            }
            if ($length -ne $entry.Length -or ($CanCheckCrc -and $crc -ne $crcs[$i])) {
                return @{ Broken = $entry.FullName; Count = $entries.Count }
            }
        }
        return @{ Broken = $null; Count = $entries.Count }
    }
    finally {
        $archive.Dispose()
    }
}

function Expand-ZipBytes([byte[]]$Data, [string]$Root) {
    $sep = [IO.Path]::DirectorySeparatorChar
    $rootPrefix = $Root.TrimEnd($sep) + $sep
    $invalid = [IO.Path]::GetInvalidFileNameChars()
    [void][IO.Directory]::CreateDirectory($Root)
    $archive = [System.IO.Compression.ZipArchive]::new([IO.MemoryStream]::new($Data), [System.IO.Compression.ZipArchiveMode]::Read)
    try {
        foreach ($entry in $archive.Entries) {
            # Come zipfile di Python: via unita', barre iniziali, '.' e '..'.
            $parts = @($entry.FullName -split '[\\/]' | Where-Object { $_ -ne '' -and $_ -ne '.' -and $_ -ne '..' })
            if ($parts.Count -gt 0 -and $parts[0] -match '^[A-Za-z]:$') {
                $parts = @($parts | Select-Object -Skip 1)
            }
            if ($parts.Count -eq 0) { continue }
            $dest = $Root
            foreach ($part in $parts) {
                foreach ($char in $invalid) { $part = $part.Replace([string]$char, '_') }
                $dest = [IO.Path]::Combine($dest, $part)
            }
            $dest = [IO.Path]::GetFullPath($dest)
            if (-not $dest.StartsWith($rootPrefix, [StringComparison]::Ordinal)) {
                Fail "voce dello zip fuori dalla cartella di destinazione: $($entry.FullName)"
            }
            if ($entry.FullName.EndsWith('/') -or $entry.FullName.EndsWith('\')) {
                [void][IO.Directory]::CreateDirectory($dest)
                continue
            }
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($dest))
            $source = $entry.Open()
            $target = [IO.File]::Create($dest)
            try {
                $source.CopyTo($target)
            }
            finally {
                $target.Dispose()
                $source.Dispose()
            }
        }
    }
    finally {
        $archive.Dispose()
    }
}

function Invoke-Unpack {
    $files = New-Object System.Collections.Generic.List[string]
    foreach ($item in $Path) {
        foreach ($resolved in @(Resolve-Inputs @($item))) {
            if (-not [IO.File]::Exists($resolved)) {
                Fail "non trovo $item"
            }
            $files.Add($resolved)
        }
    }
    $files = @(Resolve-Parts $files.ToArray())

    $pieces = New-Object System.Text.StringBuilder
    foreach ($file in $files) {
        # ReadAllText riconosce il BOM, anche UTF-16 (quello di Windows PowerShell con '>').
        $compact = [regex]::Replace([IO.File]::ReadAllText($file), '\s+', '')
        $bad = [regex]::Match($compact, '[^A-Za-z0-9+/=]')
        if ($bad.Success) {
            Fail ("{0} contiene un carattere che non e' base64: '{1}'" -f [IO.Path]::GetFileName($file), $bad.Value)
        }
        [void]$pieces.Append($compact)
    }
    try {
        $data = [Convert]::FromBase64String($pieces.ToString())
    }
    catch {
        Fail "il testo e' incompleto o troncato (manca un pezzo dell'incolla?)"
    }

    $check = Test-ZipBytes $data
    if ($check.Broken) {
        Fail "lo zip decodificato e' danneggiato, primo file rotto: $($check.Broken)"
    }
    if (-not $CanCheckCrc) {
        Say 'attenzione: Add-Type non disponibile, CRC non verificato (controllata solo la decompressione)'
    }

    if ($Extract) {
        $target = Get-FullPath $Extract
        if ([IO.File]::Exists($target)) {
            Fail "$Extract e' un file, non una cartella"
        }
        if ([IO.Directory]::Exists($target) -and @([IO.Directory]::GetFileSystemEntries($target)).Count -gt 0 -and -not $Force) {
            Fail "$Extract non e' vuota (usa -Force per estrarci dentro lo stesso)"
        }
        Expand-ZipBytes $data $target
        Say ("{0} file estratti in {1}" -f $check.Count, $Extract)
    }
    else {
        if ($Output) {
            $zipPath = Get-FullPath $Output
        }
        else {
            $zipPath = Get-ZipName $files[0]
        }
        if ([IO.File]::Exists($zipPath) -and -not $Force) {
            Fail "esiste gia' $zipPath (usa -Force per sovrascrivere)"
        }
        [IO.File]::WriteAllBytes($zipPath, $data)
        Say ("zip con {0} file scritto in {1}" -f $check.Count, (Show-Path $zipPath))
    }
    Say ("sha256 dello zip: {0}" -f (Get-Sha256Hex $data))
}


# ---------------------------------------------------------------- main

if (-not $Command -or -not $Path) {
    Say 'uso:'
    Say '  .\b64pack.ps1 pack <file o cartelle> [-Output nome] [-Split MB] [-All] [-Copy] [-Force]'
    Say '  .\b64pack.ps1 unpack <file .b64.txt o una parte> [-Output zip] [-Extract cartella] [-Force]'
    Say 'dettagli: Get-Help .\b64pack.ps1 -Detailed'
    exit 1
}
if ($PSBoundParameters.ContainsKey('Split') -and $Split -le 0) {
    Fail '-Split vuole un numero di MB maggiore di zero'
}
if ($Command -eq 'pack') {
    Invoke-Pack
}
else {
    Invoke-Unpack
}
