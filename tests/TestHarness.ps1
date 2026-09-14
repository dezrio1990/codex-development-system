[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$TestFiles
)

Set-StrictMode -Version Latest
$script:Passed = 0
$script:Failed = 0

function Describe {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock
    )

    Write-Host "`n$Name"
    & $ScriptBlock
}

function It {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock
    )

    try {
        & $ScriptBlock
        $script:Passed++
        Write-Host "PASS $Name"
    }
    catch {
        $script:Failed++
        Write-Host "FAIL $Name"
        Write-Host "  $($_.Exception.Message)"
    }
}

function Assert-Equal {
    param(
        [Parameter(Mandatory = $true)]$Actual,
        [Parameter(Mandatory = $true)]$Expected
    )

    if ($Actual -ne $Expected) {
        throw "Ожидалось '$Expected', получено '$Actual'."
    }
}

function Assert-SequenceEqual {
    param(
        [Parameter(Mandatory = $true)][object[]]$Actual,
        [Parameter(Mandatory = $true)][object[]]$Expected
    )

    if ($Actual.Count -ne $Expected.Count) {
        throw "Ожидалось элементов: $($Expected.Count), получено: $($Actual.Count)."
    }

    for ($index = 0; $index -lt $Expected.Count; $index++) {
        if ($Actual[$index] -ne $Expected[$index]) {
            throw "Элемент с индексом $index не совпадает: ожидалось '$($Expected[$index])', получено '$($Actual[$index])'."
        }
    }
}

function Assert-Throws {
    param([Parameter(Mandatory = $true)][scriptblock]$ScriptBlock)

    try {
        & $ScriptBlock
    }
    catch {
        return
    }

    throw 'Ожидалось исключение, но оно не было выброшено.'
}

foreach ($testFile in $TestFiles) {
    $resolvedPath = Resolve-Path -LiteralPath $testFile -ErrorAction Stop
    . $resolvedPath
}

Write-Host "`nВсего: PASS=$script:Passed FAIL=$script:Failed"
if ($script:Failed -gt 0) {
    exit 1
}
