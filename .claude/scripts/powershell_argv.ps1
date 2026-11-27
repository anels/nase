# Parse only: report the words of every command PowerShell finds in one text.
# Stdin: the text as one JSON string. Stdout: base64 of UTF-8 JSON. Nothing is invoked.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$text = [string](ConvertFrom-Json -InputObject ([Console]::In.ReadToEnd()))
$errors = $null
$tokens = $null
$ast = [System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$errors)
$nodes = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)
function Get-Word($element) {
    switch ($element.GetType().Name) {
        'StringConstantExpressionAst' { return @{ kind = 'constant'; value = $element.Value; text = $element.Extent.Text } }
        'ConstantExpressionAst' { return @{ kind = 'constant'; value = $element.Extent.Text; text = $element.Extent.Text } }
        'ExpandableStringExpressionAst' {
            $kind = 'constant'
            if ($element.NestedExpressions.Count) { $kind = 'expandable' }
            return @{ kind = $kind; value = $element.Value; text = $element.Extent.Text }
        }
        'CommandParameterAst' {
            $argument = $element.Argument
            if ($null -eq $argument) { return @{ kind = 'constant'; value = $element.Extent.Text; text = $element.Extent.Text } }
            $head = '-' + $element.ParameterName + ':'
            $tail = Get-Word $argument
            $adjacent = $argument.Extent.StartOffset -eq ($element.Extent.StartOffset + $head.Length)
            if ($adjacent -and $tail.kind -ne 'other') {
                # PowerShell passes `-name:` and a joined string as one argument.
                return @{ kind = $tail.kind; value = $head + $tail.value; text = $element.Extent.Text }
            }
            return @(@{ kind = 'constant'; value = $head; text = $head }, $tail)
        }
        default { return @{ kind = 'other'; value = $null; text = $element.Extent.Text } }
    }
}
$commands = New-Object System.Collections.ArrayList
foreach ($node in $nodes) {
    $words = New-Object System.Collections.ArrayList
    foreach ($element in $node.CommandElements) {
        foreach ($word in @(Get-Word $element)) { [void]$words.Add($word) }
    }
    [void]$commands.Add(@{ words = $words.ToArray() })
}
$result = @{ errors = @($errors).Count; commands = $commands.ToArray() }
$json = ConvertTo-Json -InputObject $result -Depth 6 -Compress
[Console]::Out.Write([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json)))
